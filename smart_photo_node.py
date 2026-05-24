"""
Smart Photo Enhancement Nodes for ComfyUI
==========================================
Six AI-driven nodes that replace static colour-correction filters with
content-aware, adaptive processing:

  CLIPSceneDetect          — CLIP zero-shot classification → scene label +
                             top-3 confidence scores as a JSON string
  ConditionalESRGANBlend   — scene-aware ESRGAN gating: blends original with
                             the upscaled result at a scene-tuned ratio
                             (portrait/night skip ESRGAN; landscape/beach keep full)
  AdaptivePhotoGrade       — scene-tuned exposure/contrast/saturation/detail;
                             blends multiple scene profiles weighted by CLIP scores
  SkyEnhance               — HSV sky mask + graduated exposure & saturation boost
  DepthSelectiveSharpen    — Depth-Anything depth map → foreground sharpening only
                             (no background blur by default — avoids portrait-mode look)
  WritePhotoMetadata       — per-photo JSON report: scene scores, ESRGAN mode,
                             grading profile, sky coverage, depth settings, models

All heavy models are loaded once and kept in _MODEL_CACHE between prompts.
"""

import json
import re
import torch
import numpy as np
import cv2
from PIL import Image

# ---------------------------------------------------------------------------
# Global model cache — prevents reloading 100–600 MB models every frame
# ---------------------------------------------------------------------------
_MODEL_CACHE: dict = {}


def _cached_model(key: str, loader_fn):
    """Return a cached model, loading it on the first call."""
    if key not in _MODEL_CACHE:
        _MODEL_CACHE[key] = loader_fn()
    return _MODEL_CACHE[key]


# ---------------------------------------------------------------------------
# CLIPSceneDetect
# ---------------------------------------------------------------------------
class CLIPSceneDetect:
    """
    Zero-shot scene classification using OpenAI CLIP (ViT-B/32, ~600 MB).

    Matches the photo against 8 descriptive text prompts via cosine similarity
    and emits:
      • scene_type  — winning scene label (STRING) for downstream nodes
      • scene_scores — top-3 scene scores as a normalised JSON string
                       e.g. '{"landscape": 0.55, "golden_hour": 0.35, "overcast": 0.10}'

    Runs on the ORIGINAL image before ESRGAN so the score can gate upscaling
    in ConditionalESRGANBlend.

    Scene labels: portrait | landscape | night | indoor |
                  golden_hour | overcast | beach | street
    """

    # Text prompts whose cosine similarity to the image selects the scene
    SCENE_PROMPTS = [
        "a portrait photograph of a person or people",
        "a landscape photograph of nature or scenery outdoors",
        "a night photograph taken in low light or darkness",
        "an indoor photograph inside a room or building",
        "a golden hour or sunset photograph with warm orange light",
        "an overcast or cloudy day outdoor photograph",
        "a beach, ocean, or waterfront photograph",
        "a street, city, or urban photograph",
    ]
    SCENE_LABELS = [
        "portrait", "landscape", "night", "indoor",
        "golden_hour", "overcast", "beach", "street",
    ]

    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {"image": ("IMAGE",)}}

    RETURN_TYPES  = ("IMAGE", "STRING", "STRING")
    RETURN_NAMES  = ("image", "scene_type", "scene_scores")
    FUNCTION      = "detect"
    CATEGORY      = "image/smart"

    def detect(self, image):
        from transformers import CLIPProcessor, CLIPModel

        device = "cuda" if torch.cuda.is_available() else "cpu"

        def _load():
            print("[CLIPSceneDetect] Loading CLIP ViT-B/32…")
            m = CLIPModel.from_pretrained("openai/clip-vit-base-patch32").to(device).eval()
            p = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")
            return m, p

        model, processor = _cached_model("clip_scene", _load)

        # Use the first image in the batch; all frames are the same scene
        img_np  = (image[0].cpu().numpy() * 255).astype(np.uint8)
        img_pil = Image.fromarray(img_np)

        inputs = processor(
            text=self.SCENE_PROMPTS,
            images=img_pil,
            return_tensors="pt",
            padding=True,
        ).to(device)

        with torch.no_grad():
            logits = model(**inputs).logits_per_image[0]
            probs  = logits.softmax(dim=0).cpu()

        # Winning scene for hard-switch compatibility
        idx   = int(probs.argmax())
        scene = self.SCENE_LABELS[idx]
        conf  = float(probs[idx])
        print(f"[CLIPSceneDetect] → {scene} ({conf:.1%})")

        # Build top-3 normalised scores for blending downstream nodes.
        # Normalising to sum=1.0 lets downstream code weight-blend without
        # worrying about softmax temperature or total mass.
        top3_idx   = probs.topk(3).indices.tolist()
        top3_sum   = sum(float(probs[i]) for i in top3_idx)
        top3_scores = {
            self.SCENE_LABELS[i]: round(float(probs[i]) / top3_sum, 4)
            for i in top3_idx
        }
        scene_scores = json.dumps(top3_scores)
        print(f"[CLIPSceneDetect] Top-3 scores: {top3_scores}")

        return (image, scene, scene_scores)


# ---------------------------------------------------------------------------
# ConditionalESRGANBlend
# ---------------------------------------------------------------------------
class ConditionalESRGANBlend:
    """
    Scene-aware ESRGAN gating via pixel-level blending.

    Real-ESRGAN 4× upscale is expensive (~15–20 s/image) and introduces:
      • synthetic texture and crispy foliage on already-sharp images
      • waxy skin and invented micro-detail on portraits
      • amplified JPEG block artifacts on high-ISO night shots

    This node blends the ESRGAN output with the original at a scene-tuned
    ratio so over-processed images revert to a safer look without removing
    the upscale step from the ComfyUI graph entirely.

    Blend ratios (0.0 = full original, 1.0 = full ESRGAN):
      portrait / night → 0.0   (skip — never benefits)
      indoor           → 0.25  (light touch for interior textures)
      golden_hour      → 0.60  (moderate — warm skin tones are sensitive)
      overcast / street → 0.75 (strong but not maximum)
      landscape / beach → 1.0  (full — these gain the most from ESRGAN)
      default          → 1.0

    When scene_scores (JSON) are provided, the effective ratio is a
    confidence-weighted average of the per-scene ratios — e.g. a 55/35/10
    split between landscape, golden_hour, and overcast yields ~0.86 instead
    of the hard 1.0 for landscape alone.

    The esrgan_mode output string ("skip" / "weak" / "full") is written into
    the metadata sidecar for debugging.
    """

    # Per-scene blend ratios: 0.0 = original, 1.0 = pure ESRGAN
    ESRGAN_RATIOS = {
        "portrait":    0.0,
        "night":       0.0,
        "indoor":      0.25,
        "golden_hour": 0.60,
        "overcast":    0.75,
        "street":      0.75,
        "landscape":   1.0,
        "beach":       1.0,
        "default":     1.0,
    }

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "original":     ("IMAGE",),
                "esrgan":       ("IMAGE",),
                "scene_type":   ("STRING", {"default": "default"}),
                "scene_scores": ("STRING", {"default": "{}"}),
            }
        }

    RETURN_TYPES  = ("IMAGE", "STRING")
    RETURN_NAMES  = ("image", "esrgan_mode")
    FUNCTION      = "blend"
    CATEGORY      = "image/smart"

    def blend(self, original, esrgan, scene_type: str, scene_scores: str):
        ratio = self._compute_ratio(scene_type, scene_scores)

        if ratio <= 0.02:
            esrgan_mode = "skip"
        elif ratio >= 0.98:
            esrgan_mode = "full"
        else:
            esrgan_mode = "weak"

        print(f"[ConditionalESRGANBlend] scene={scene_type} ratio={ratio:.2f} mode={esrgan_mode}")

        if esrgan_mode == "skip":
            return (original, esrgan_mode)
        if esrgan_mode == "full":
            return (esrgan, esrgan_mode)

        # Pixel-level blend: result = original*(1-r) + esrgan*r
        # Both tensors are [B, H, W, C] float32 0..1
        blended = original * (1.0 - ratio) + esrgan * ratio
        return (torch.clamp(blended, 0, 1), esrgan_mode)

    def _compute_ratio(self, scene_type: str, scene_scores_json: str) -> float:
        """
        Return the ESRGAN blend ratio.  When scene_scores carries top-3
        confidence values, returns a weighted average of per-scene ratios.
        Falls back to the hard per-scene ratio if parsing fails.
        """
        base_ratio = self.ESRGAN_RATIOS.get(scene_type, self.ESRGAN_RATIOS["default"])

        try:
            scores = json.loads(scene_scores_json)
            if not scores:
                return base_ratio
        except Exception:
            return base_ratio

        # Confidence-weighted blend of ratios across the top-3 scenes
        total_weight = sum(scores.values())
        if total_weight < 1e-6:
            return base_ratio

        weighted_ratio = sum(
            self.ESRGAN_RATIOS.get(s, self.ESRGAN_RATIOS["default"]) * w
            for s, w in scores.items()
        ) / total_weight
        return float(weighted_ratio)


# ---------------------------------------------------------------------------
# AdaptivePhotoGrade
# ---------------------------------------------------------------------------
class AdaptivePhotoGrade:
    """
    Scene-adaptive colour grading node.

    Applies exposure correction (linear-light), contrast, saturation, and
    guided-filter clarity enhancement with parameters tuned per scene type.

    When scene_scores (JSON) from CLIPSceneDetect are available, the grading
    parameters are blended across the top-3 scene profiles weighted by their
    confidence values — e.g. a 55/35/10 landscape/golden_hour/overcast split
    produces a weighted average of those three profiles, avoiding the hard
    cut artefacts caused by a single misclassified label.

    Falls back to the balanced 'default' profile for unknown scene labels or
    when scene_scores is empty/unparseable.
    """

    # Per-scene profiles: exposure in stops, contrast factor, saturation
    # multiplier, detail enhancement multiplier, denoise strength (0..1).
    PROFILES = {
        # Portraits: gentle — preserve skin tones, avoid over-sharpening hair
        "portrait":    dict(stops=0.30, contrast=1.00, saturation=1.00, detail=1.2, denoise=0.15),
        # Landscapes: vivid — strong clarity, saturated skies & greens
        "landscape":   dict(stops=0.20, contrast=1.05, saturation=1.15, detail=1.8, denoise=0.05),
        # Night: lift shadows aggressively, reduce sharpening (hides noise)
        "night":       dict(stops=0.80, contrast=1.00, saturation=0.90, detail=0.8, denoise=0.30),
        # Indoor: correct typically warm/dim ambient light
        "indoor":      dict(stops=0.50, contrast=1.00, saturation=1.05, detail=1.3, denoise=0.10),
        # Golden hour: enhance warmth, lift shadow detail
        "golden_hour": dict(stops=0.25, contrast=1.05, saturation=1.20, detail=1.5, denoise=0.05),
        # Overcast: punch contrast to compensate for flat light
        "overcast":    dict(stops=0.40, contrast=1.05, saturation=1.10, detail=1.6, denoise=0.08),
        # Beach: bright scene, protect highlights, boost blues/greens
        "beach":       dict(stops=0.15, contrast=1.00, saturation=1.20, detail=1.7, denoise=0.05),
        # Street: punchy contrast, neutral colour
        "street":      dict(stops=0.35, contrast=1.05, saturation=1.05, detail=1.5, denoise=0.08),
        # Balanced fallback for unrecognised labels
        "default":     dict(stops=0.40, contrast=1.00, saturation=1.05, detail=1.5, denoise=0.10),
    }

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images":       ("IMAGE",),
                "scene_type":   ("STRING", {"default": "default"}),
                "scene_scores": ("STRING", {"default": "{}"}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION     = "grade"
    CATEGORY     = "image/smart"

    def grade(self, images, scene_type: str, scene_scores: str = "{}"):
        p = self._resolve_profile(scene_type, scene_scores)
        print(f"[AdaptivePhotoGrade] Scene={scene_type} → {p}")

        results = []
        for img in images:
            arr = img.cpu().numpy().copy()   # [H, W, C] float32 0..1
            arr = self._apply_exposure(arr, p["stops"])
            arr = self._apply_contrast(arr, p["contrast"])
            arr = self._apply_saturation(arr, p["saturation"])
            arr = self._apply_detail(arr, p["detail"], p["denoise"])
            results.append(torch.from_numpy(arr.clip(0, 1)).float())

        return (torch.stack(results),)

    def _resolve_profile(self, scene_type: str, scene_scores_json: str) -> dict:
        """
        Return a grading profile by blending top-3 scene profiles weighted by
        their CLIP confidence scores.  Falls back to hard scene_type lookup when
        the JSON is absent or malformed.
        """
        try:
            scores = json.loads(scene_scores_json)
            if not scores:
                raise ValueError("empty scores")
        except Exception:
            return self.PROFILES.get(scene_type, self.PROFILES["default"])

        param_keys   = list(next(iter(self.PROFILES.values())).keys())
        total_weight = sum(scores.values())
        if total_weight < 1e-6:
            return self.PROFILES.get(scene_type, self.PROFILES["default"])

        blended = {k: 0.0 for k in param_keys}
        for scene, weight in scores.items():
            profile = self.PROFILES.get(scene, self.PROFILES["default"])
            for k in param_keys:
                blended[k] += profile[k] * (weight / total_weight)
        return blended

    # -- helpers ------------------------------------------------------------

    def _apply_exposure(self, img: np.ndarray, stops: float) -> np.ndarray:
        """
        Per-stop exposure adjustment in linear light.
        Converts sRGB → linear, multiplies by 2^stops, clips highlights, converts back.
        Simple and photographic — avoids Reinhard's tonal compression which
        would darken already-bright Fuji photos.
        """
        linear = img ** 2.2                    # sRGB → approximate linear
        linear = linear * (2.0 ** stops)       # shift by N stops (positive = brighter)
        return np.clip(linear ** (1.0 / 2.2), 0, 1)  # back to sRGB, clip overexposed

    def _apply_contrast(self, img: np.ndarray, factor: float) -> np.ndarray:
        """Simple linear contrast around 0.5 midpoint."""
        return np.clip((img - 0.5) * factor + 0.5, 0, 1)

    def _apply_saturation(self, img: np.ndarray, factor: float) -> np.ndarray:
        """HSV saturation boost; factor=1.0 is a no-op."""
        u8  = (img * 255).astype(np.uint8)
        hsv = cv2.cvtColor(u8, cv2.COLOR_RGB2HSV).astype(np.float32)
        hsv[:, :, 1] = np.clip(hsv[:, :, 1] * factor, 0, 255)
        return cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2RGB).astype(np.float32) / 255.0

    def _apply_detail(self, img: np.ndarray, mult: float, denoise: float) -> np.ndarray:
        """
        Clarity / structure boost via edge-preserving decomposition.

        Uses cv2.ximgproc.guidedFilter when opencv-contrib is available
        (provides the best edge-preserving base layer separation).
        Falls back to a bilateral filter base when ximgproc is absent.

        Separates base (low-freq) from detail (high-freq), scales detail by
        mult, optionally denoises the base layer via bilateral filter.
        """
        u8 = (img * 255).astype(np.uint8)

        # Prefer guided filter (opencv-contrib); fall back to bilateral
        try:
            base = cv2.ximgproc.guidedFilter(u8, u8, radius=8, eps=int(0.01 * 255 ** 2))
        except AttributeError:
            # opencv-contrib not installed — bilateral filter gives a similar
            # edge-preserving smooth base at slightly lower quality
            sigma = max(15, int(denoise * 75))
            base  = cv2.bilateralFilter(u8, d=9, sigmaColor=sigma, sigmaSpace=sigma)

        detail = u8.astype(np.float32) - base.astype(np.float32)

        # Optionally soften the base to reduce noise before adding detail back
        if denoise > 0.05:
            sigma = int(denoise * 75)
            base  = cv2.bilateralFilter(base, d=5, sigmaColor=sigma, sigmaSpace=sigma)

        enhanced = base.astype(np.float32) + detail * mult
        return np.clip(enhanced / 255.0, 0, 1)


# ---------------------------------------------------------------------------
# SkyEnhance
# ---------------------------------------------------------------------------
class SkyEnhance:
    """
    Sky region detection and graduated enhancement — no ML model required.

    Detects sky using HSV colour ranges (blue sky, white clouds, sunset tones)
    combined with a spatial prior (sky lives in the upper portion of the frame).
    Applies independent exposure + saturation adjustments to the sky mask,
    blended smoothly with the rest of the image.

    Works on any outdoor shot; portraits and indoor shots receive no change
    because the sky mask will be near zero.
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images":         ("IMAGE",),
                "sky_exposure":   ("FLOAT", {"default": 0.30, "min": -1.0, "max": 1.0, "step": 0.05}),
                "sky_saturation": ("FLOAT", {"default": 1.20, "min":  0.5, "max": 2.0, "step": 0.05}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION     = "enhance"
    CATEGORY     = "image/smart"

    def enhance(self, images, sky_exposure: float = 0.30, sky_saturation: float = 1.20):
        results = []
        for img in images:
            arr      = (img.cpu().numpy() * 255).astype(np.uint8)
            mask     = self._detect_sky(arr)
            enhanced = self._apply_sky(arr, mask, sky_exposure, sky_saturation)
            results.append(torch.from_numpy(enhanced.astype(np.float32) / 255.0))
        return (torch.stack(results),)

    def _detect_sky(self, img_rgb: np.ndarray) -> np.ndarray:
        """
        Build a soft float sky mask [0..1] using three HSV colour bands
        plus a vertical spatial prior (sky = upper image region).
        """
        h   = img_rgb.shape[0]
        hsv = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2HSV).astype(np.float32)
        H, S, V = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]

        # Band 1: Blue daytime sky  (hue 90–140 in OpenCV 0–180 scale)
        blue   = ((H >= 90) & (H <= 140) & (S >= 30) & (V >= 50)).astype(np.float32)

        # Band 2: White/grey clouds  (low saturation, bright)
        clouds = ((S < 40) & (V >= 180)).astype(np.float32)

        # Band 3: Sunset/golden sky  (hue 0–25 or 155–180, moderate sat)
        sunset = (((H <= 25) | (H >= 155)) & (S >= 40) & (V >= 100)).astype(np.float32)

        raw = np.clip(blue + clouds + sunset, 0, 1)

        # Vertical gradient prior: top row = 1.2, bottom row = 0.0
        y_weight = np.linspace(1.2, 0.0, h)[:, np.newaxis]
        raw      = raw * y_weight

        # Morphological close to fill gaps between cloud patches
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
        raw    = cv2.morphologyEx(raw, cv2.MORPH_CLOSE, kernel)

        # Large Gaussian blur for smooth mask edges (avoids halo artifacts)
        mask = cv2.GaussianBlur(raw, (51, 51), 0)
        return np.clip(mask, 0, 1)

    def _apply_sky(self, img_rgb: np.ndarray, mask: np.ndarray,
                   sky_exposure: float, sky_saturation: float) -> np.ndarray:
        """Blend sky-enhanced pixels into the original image using the mask."""
        orig = img_rgb.astype(np.float32)

        # Exposure adjustment in linear light — simple shift, no Reinhard compression
        linear  = (orig / 255.0) ** 2.2
        linear  = np.clip(linear * (2.0 ** sky_exposure), 0, 1)
        sky_exp = np.clip(linear ** (1.0 / 2.2) * 255, 0, 255).astype(np.uint8)

        # Saturation boost in HSV
        hsv     = cv2.cvtColor(sky_exp, cv2.COLOR_RGB2HSV).astype(np.float32)
        hsv[:, :, 1] = np.clip(hsv[:, :, 1] * sky_saturation, 0, 255)
        sky_sat = cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2RGB).astype(np.float32)

        # Alpha blend: mask=1 → sky-enhanced, mask=0 → original
        mask3  = mask[:, :, np.newaxis]
        result = orig * (1.0 - mask3) + sky_sat * mask3
        return np.clip(result, 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# DepthSelectiveSharpen
# ---------------------------------------------------------------------------
class DepthSelectiveSharpen:
    """
    Depth-guided selective sharpening using Depth Anything V2 Small (~100 MB).

    Estimates a monocular depth map, then:
      • Foreground (near): unsharp-mask sharpening (foreground_sharpen controls
        the detail multiplier; 1.0 = no change, 2.0 = strong sharpening)
      • Background (far):  Gaussian blur (background_blur controls kernel size;
        0.0 = no blur — the conservative default — 1.0 = heavy softening)

    Background blur is disabled by default (0.0) because it tends to produce
    an artificial "smartphone portrait mode" look on images that were naturally
    focused.  Enable it explicitly when you want that effect.
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images":             ("IMAGE",),
                "foreground_sharpen": ("FLOAT", {"default": 1.50, "min": 1.0, "max": 3.0, "step": 0.1}),
                # 0.0 = disabled by default — avoids synthetic portrait-mode blur
                "background_blur":    ("FLOAT", {"default": 0.0,  "min": 0.0, "max": 1.0, "step": 0.1}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION     = "process"
    CATEGORY     = "image/smart"

    def process(self, images, foreground_sharpen: float = 1.5, background_blur: float = 0.0):
        device = "cuda" if torch.cuda.is_available() else "cpu"

        def _load():
            print("[DepthSelectiveSharpen] Loading Depth Anything V2 Small…")
            from transformers import pipeline as hf_pipeline
            return hf_pipeline(
                task="depth-estimation",
                model="depth-anything/Depth-Anything-V2-Small-hf",
                device=0 if device == "cuda" else -1,
            )

        depth_pipe = _cached_model("depth_anything_v2", _load)

        results = []
        for img in images:
            arr     = (img.cpu().numpy() * 255).astype(np.uint8)
            fg_mask = self._depth_foreground_mask(arr, depth_pipe)
            result  = self._blend_sharp_blur(arr, fg_mask, foreground_sharpen, background_blur)
            results.append(torch.from_numpy(result.astype(np.float32) / 255.0))

        return (torch.stack(results),)

    def _depth_foreground_mask(self, img_rgb: np.ndarray, depth_pipe) -> np.ndarray:
        """
        Run Depth Anything on the image, normalise to [0,1], resize to match,
        then invert so that near=1 (foreground) and far=0 (background).
        """
        h, w    = img_rgb.shape[:2]
        img_pil = Image.fromarray(img_rgb)

        depth_out  = depth_pipe(img_pil)
        depth_arr  = np.array(depth_out["depth"], dtype=np.float32)

        # Normalise depth to 0..1
        d_min, d_max = depth_arr.min(), depth_arr.max()
        depth_norm   = (depth_arr - d_min) / (d_max - d_min + 1e-8)

        # Resize depth map to original image size
        depth_resized = cv2.resize(depth_norm, (w, h), interpolation=cv2.INTER_LINEAR)

        # Depth Anything: larger value = farther away → invert for foreground mask
        fg_mask = 1.0 - depth_resized

        # Smooth mask to avoid hard transitions at object boundaries
        fg_mask = cv2.GaussianBlur(fg_mask, (31, 31), 0)
        return fg_mask.clip(0, 1)

    def _blend_sharp_blur(self, img_u8: np.ndarray, fg_mask: np.ndarray,
                          fg_sharpen: float, bg_blur: float) -> np.ndarray:
        """Blend foreground-sharpened and (optionally) background-blurred versions."""
        fg_mask3 = fg_mask[:, :, np.newaxis]

        # Foreground: unsharp mask sharpening
        if fg_sharpen > 1.0:
            blur      = cv2.GaussianBlur(img_u8.astype(np.float32), (0, 0), 2.0)
            detail    = img_u8.astype(np.float32) - blur
            sharpened = np.clip(img_u8.astype(np.float32) + detail * (fg_sharpen - 1.0), 0, 255)
        else:
            sharpened = img_u8.astype(np.float32)

        # Background: Gaussian blur (skipped entirely when bg_blur=0.0)
        if bg_blur > 0.05:
            ksize   = int(bg_blur * 10) * 2 + 1   # always odd
            blurred = cv2.GaussianBlur(img_u8, (ksize, ksize), bg_blur * 5).astype(np.float32)
        else:
            blurred = img_u8.astype(np.float32)

        # Combine: near pixels get sharpened version, far pixels get blurred (or unchanged)
        blended = sharpened * fg_mask3 + blurred * (1.0 - fg_mask3)
        return np.clip(blended, 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# WritePhotoMetadata
# ---------------------------------------------------------------------------
class WritePhotoMetadata:
    """
    Writes a per-photo JSON metadata file to the ComfyUI output directory.

    The Ruby photo-enhance.rb script downloads this file after the image,
    reads the AI pipeline details (scene scores, ESRGAN mode, grading profile,
    sky coverage, depth settings), and generates a human-readable .md report
    alongside the enhanced JPEG.

    filename_prefix must match the prefix injected into SaveImage so the Ruby
    script can find both files by the same prefix.
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "image":            ("IMAGE",),
                "scene_type":       ("STRING",  {"default": "unknown"}),
                "scene_scores":     ("STRING",  {"default": "{}"}),
                "esrgan_mode":      ("STRING",  {"default": "full"}),
                # Both injected per-prompt by photo-enhance.rb's inject_input
                "filename_prefix":  ("STRING",  {"default": "enhanced_"}),
                "source_filename":  ("STRING",  {"default": "photo"}),
            }
        }

    # Pass image through unchanged; side-effect is writing the metadata file
    RETURN_TYPES = ("IMAGE",)
    FUNCTION     = "write"
    CATEGORY     = "image/smart"

    # Mirrors AdaptivePhotoGrade — kept in sync via shared reference
    PROFILES = AdaptivePhotoGrade.PROFILES

    def write(self, image, scene_type: str, scene_scores: str,
              esrgan_mode: str, filename_prefix: str, source_filename: str):
        import datetime
        import os

        # Resolve ComfyUI output directory via its internal module
        try:
            import folder_paths
            out_dir = folder_paths.get_output_directory()
        except Exception:
            out_dir = "/ephemeral/comfyui/output"

        profile      = self._resolve_profile(scene_type, scene_scores)
        sky_coverage = self._sky_coverage(image[0])

        # Parse scene_scores JSON for inclusion in metadata
        try:
            scores_dict = json.loads(scene_scores)
        except Exception:
            scores_dict = {}

        # source_filename is the upload name on ComfyUI, e.g. "DSCF5434.JPG.orient.JPG"
        # Strip the .orient.<ext> suffix if present to recover the original base name
        base = os.path.basename(source_filename)
        base = re.sub(r"\.orient\.[A-Za-z]+$", "", base)

        meta = {
            "generated_at":    datetime.datetime.utcnow().isoformat() + "Z",
            "source_filename": base,
            "scene_type":      scene_type,
            "scene_scores":    scores_dict,
            "esrgan_mode":     esrgan_mode,
            "enhancement_profile": {
                "exposure_stops":   round(profile["stops"],      4),
                "contrast_factor":  round(profile["contrast"],   4),
                "saturation_mult":  round(profile["saturation"], 4),
                "detail_mult":      round(profile["detail"],     4),
                "denoise_strength": round(profile["denoise"],    4),
            },
            "sky": {
                "coverage_pct":  round(sky_coverage * 100, 1),
                "sky_exposure":  0.30,
                "sky_saturation": 1.20,
            },
            "depth_sharpen": {
                "foreground_sharpen": 1.50,
                # background_blur is 0.0 by default — only non-zero if overridden
                "background_blur":    0.0,
            },
            "models": {
                "upscaler":     "realesr-general-x4v3 (Real-ESRGAN, GPU)",
                "face_restore": "CodeFormer fidelity=0.7 (GPU)",
                "scene_detect": "CLIP ViT-B/32 (openai/clip-vit-base-patch32)",
                "depth":        "Depth Anything V2 Small (GPU)",
            },
        }

        # Write as a prefixed file so Ruby can download it by prefix
        meta_path = os.path.join(out_dir, f"{filename_prefix}meta.json")
        with open(meta_path, "w") as f:
            json.dump(meta, f, indent=2)
        print(
            f"[WritePhotoMetadata] Wrote {meta_path} "
            f"(scene={scene_type}, esrgan={esrgan_mode}, sky={sky_coverage:.1%})"
        )

        return (image,)

    def _resolve_profile(self, scene_type: str, scene_scores_json: str) -> dict:
        """Blend top-3 scene profiles by confidence weight, same logic as AdaptivePhotoGrade."""
        try:
            scores = json.loads(scene_scores_json)
            if not scores:
                raise ValueError("empty")
        except Exception:
            return self.PROFILES.get(scene_type, self.PROFILES["default"])

        param_keys   = list(next(iter(self.PROFILES.values())).keys())
        total_weight = sum(scores.values())
        if total_weight < 1e-6:
            return self.PROFILES.get(scene_type, self.PROFILES["default"])

        blended = {k: 0.0 for k in param_keys}
        for scene, weight in scores.items():
            profile = self.PROFILES.get(scene, self.PROFILES["default"])
            for k in param_keys:
                blended[k] += profile[k] * (weight / total_weight)
        return blended

    def _sky_coverage(self, img_tensor) -> float:
        """Re-use SkyEnhance's mask logic to estimate sky % for reporting."""
        try:
            arr    = (img_tensor.cpu().numpy() * 255).astype(np.uint8)
            helper = SkyEnhance()
            mask   = helper._detect_sky(arr)
            return float(mask.mean())
        except Exception:
            return 0.0


# ---------------------------------------------------------------------------
# CodeFormerRestore (stub)
# ---------------------------------------------------------------------------
class CodeFormerRestore:
    """
    Passthrough stub for CodeFormer face restoration.

    The real implementation requires the comfyui-reactor-node or similar
    custom node package.  This stub passes the image through unchanged so
    the rest of the pipeline (CLIP, grading, sky, depth) can be tested
    without CodeFormer installed.

    TODO: replace with the real CodeFormer node once the package is
    installed (e.g. via ComfyUI Manager or manual install of
    github.com/Gourieff/comfyui-reactor-node).
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "image":    ("IMAGE",),
                "fidelity": ("FLOAT", {"default": 0.7, "min": 0.0, "max": 1.0, "step": 0.05}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION     = "restore"
    CATEGORY     = "image/smart"

    def restore(self, image, fidelity: float = 0.7):
        print(f"[CodeFormerRestore] STUB — passing image through (fidelity={fidelity} ignored)")
        return (image,)


# ---------------------------------------------------------------------------
# ComfyUI node registration
# ---------------------------------------------------------------------------
NODE_CLASS_MAPPINGS = {
    "CLIPSceneDetect":          CLIPSceneDetect,
    "ConditionalESRGANBlend":   ConditionalESRGANBlend,
    "AdaptivePhotoGrade":       AdaptivePhotoGrade,
    "SkyEnhance":               SkyEnhance,
    "DepthSelectiveSharpen":    DepthSelectiveSharpen,
    "WritePhotoMetadata":       WritePhotoMetadata,
    # Stub registered last so the real node from another package takes priority
    # if comfyui-reactor-node or similar is installed alongside this file.
    "CodeFormerRestore":        CodeFormerRestore,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "CLIPSceneDetect":          "CLIP Scene Detect",
    "ConditionalESRGANBlend":   "Conditional ESRGAN Blend",
    "AdaptivePhotoGrade":       "Adaptive Photo Grade",
    "SkyEnhance":               "Sky Enhance",
    "DepthSelectiveSharpen":    "Depth Selective Sharpen",
    "WritePhotoMetadata":       "Write Photo Metadata",
    "CodeFormerRestore":        "CodeFormer Restore (stub — install reactor-node for real impl)",
}

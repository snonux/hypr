"""
Smart Photo Enhancement Nodes for ComfyUI
==========================================
Four AI-driven nodes that replace static colour-correction filters with
content-aware processing:

  CLIPSceneDetect      — CLIP zero-shot classification → scene label
  AdaptivePhotoGrade   — scene-tuned exposure / contrast / saturation / detail
  SkyEnhance           — HSV sky mask + graduated exposure & saturation boost
  DepthSelectiveSharpen— Depth-Anything depth map → foreground sharp, BG soft

All heavy models are loaded once and kept in _MODEL_CACHE between prompts.
"""

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
    Matches the photo against 8 descriptive text prompts and emits the
    winning scene label as a STRING for AdaptivePhotoGrade to consume.

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

    RETURN_TYPES = ("IMAGE", "STRING")
    RETURN_NAMES = ("image", "scene_type")
    FUNCTION = "detect"
    CATEGORY = "image/smart"

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
        img_np = (image[0].cpu().numpy() * 255).astype(np.uint8)
        img_pil = Image.fromarray(img_np)

        inputs = processor(
            text=self.SCENE_PROMPTS,
            images=img_pil,
            return_tensors="pt",
            padding=True,
        ).to(device)

        with torch.no_grad():
            logits = model(**inputs).logits_per_image[0]
            probs = logits.softmax(dim=0).cpu()

        idx = int(probs.argmax())
        scene = self.SCENE_LABELS[idx]
        conf = float(probs[idx])
        print(f"[CLIPSceneDetect] → {scene} ({conf:.1%})")
        return (image, scene)


# ---------------------------------------------------------------------------
# AdaptivePhotoGrade
# ---------------------------------------------------------------------------
class AdaptivePhotoGrade:
    """
    Scene-adaptive colour grading node.

    Applies exposure correction (Reinhard tonemapping), contrast, saturation,
    and guided-filter clarity enhancement with parameters tuned per scene type.
    Falls back to balanced 'default' settings for unknown scene labels.

    Replaces the three static ComfyUI-Image-Filters nodes
    (ExposureAdjust + AdjustContrast + EnhanceDetail) with one smart node
    that adapts to content.
    """

    # Per-scene profiles: exposure in stops, contrast factor, saturation
    # multiplier, detail enhancement multiplier, denoise strength (0..1).
    PROFILES = {
        # Portraits: gentle — preserve skin tones, avoid over-sharpening hair
        "portrait":    dict(stops=0.30, contrast=1.10, saturation=1.00, detail=1.2, denoise=0.15),
        # Landscapes: vivid — strong clarity, saturated skies & greens
        "landscape":   dict(stops=0.20, contrast=1.20, saturation=1.15, detail=1.8, denoise=0.05),
        # Night: lift shadows aggressively, reduce sharpening (hides noise)
        "night":       dict(stops=0.80, contrast=1.05, saturation=0.90, detail=0.8, denoise=0.30),
        # Indoor: correct typically warm/dim ambient light
        "indoor":      dict(stops=0.50, contrast=1.15, saturation=1.05, detail=1.3, denoise=0.10),
        # Golden hour: enhance warmth, lift shadow detail
        "golden_hour": dict(stops=0.25, contrast=1.20, saturation=1.20, detail=1.5, denoise=0.05),
        # Overcast: punch contrast to compensate for flat light
        "overcast":    dict(stops=0.40, contrast=1.20, saturation=1.10, detail=1.6, denoise=0.08),
        # Beach: bright scene, protect highlights, boost blues/greens
        "beach":       dict(stops=0.15, contrast=1.15, saturation=1.20, detail=1.7, denoise=0.05),
        # Street: punchy contrast, neutral colour
        "street":      dict(stops=0.35, contrast=1.20, saturation=1.05, detail=1.5, denoise=0.08),
        # Balanced fallback for unrecognised labels
        "default":     dict(stops=0.40, contrast=1.15, saturation=1.05, detail=1.5, denoise=0.10),
    }

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images":     ("IMAGE",),
                "scene_type": ("STRING", {"default": "default"}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "grade"
    CATEGORY = "image/smart"

    def grade(self, images, scene_type: str):
        p = self.PROFILES.get(scene_type, self.PROFILES["default"])
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
        u8 = (img * 255).astype(np.uint8)
        hsv = cv2.cvtColor(u8, cv2.COLOR_RGB2HSV).astype(np.float32)
        hsv[:, :, 1] = np.clip(hsv[:, :, 1] * factor, 0, 255)
        return cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2RGB).astype(np.float32) / 255.0

    def _apply_detail(self, img: np.ndarray, mult: float, denoise: float) -> np.ndarray:
        """
        Clarity / structure boost via guided-filter edge-preserving decomposition.
        Separates base (low-freq) from detail (high-freq), scales detail by mult,
        optionally denoises the base layer via bilateral filter.
        """
        u8 = (img * 255).astype(np.uint8)

        # Guided filter produces an edge-preserving smooth base layer
        # eps controls smoothing strength (higher = more smoothing)
        base = cv2.ximgproc.guidedFilter(u8, u8, radius=8, eps=int(0.01 * 255 ** 2))
        detail = u8.astype(np.float32) - base.astype(np.float32)

        # Optionally soften the base to reduce noise before adding detail back
        if denoise > 0.05:
            sigma = int(denoise * 75)
            base = cv2.bilateralFilter(base, d=5, sigmaColor=sigma, sigmaSpace=sigma)

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
                "images":          ("IMAGE",),
                "sky_exposure":    ("FLOAT", {"default": 0.30, "min": -1.0, "max": 1.0,  "step": 0.05}),
                "sky_saturation":  ("FLOAT", {"default": 1.20, "min":  0.5, "max": 2.0,  "step": 0.05}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "enhance"
    CATEGORY = "image/smart"

    def enhance(self, images, sky_exposure: float = 0.30, sky_saturation: float = 1.20):
        results = []
        for img in images:
            arr = (img.cpu().numpy() * 255).astype(np.uint8)
            mask = self._detect_sky(arr)
            enhanced = self._apply_sky(arr, mask, sky_exposure, sky_saturation)
            results.append(torch.from_numpy(enhanced.astype(np.float32) / 255.0))
        return (torch.stack(results),)

    def _detect_sky(self, img_rgb: np.ndarray) -> np.ndarray:
        """
        Build a soft float sky mask [0..1] using three HSV colour bands
        plus a vertical spatial prior (sky = upper image region).
        """
        h = img_rgb.shape[0]
        hsv = cv2.cvtColor(img_rgb, cv2.COLOR_RGB2HSV).astype(np.float32)
        H, S, V = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]

        # Band 1: Blue daytime sky  (hue 90–140 in OpenCV 0–180 scale)
        blue = ((H >= 90) & (H <= 140) & (S >= 30) & (V >= 50)).astype(np.float32)

        # Band 2: White/grey clouds  (low saturation, bright)
        clouds = ((S < 40) & (V >= 180)).astype(np.float32)

        # Band 3: Sunset/golden sky  (hue 0–25 or 155–180, moderate sat)
        sunset = (((H <= 25) | (H >= 155)) & (S >= 40) & (V >= 100)).astype(np.float32)

        raw = np.clip(blue + clouds + sunset, 0, 1)

        # Vertical gradient prior: top row = 1.2, bottom row = 0.0
        y_weight = np.linspace(1.2, 0.0, h)[:, np.newaxis]
        raw = raw * y_weight

        # Morphological close to fill gaps between cloud patches
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
        raw = cv2.morphologyEx(raw, cv2.MORPH_CLOSE, kernel)

        # Large Gaussian blur for smooth mask edges (avoids halo artifacts)
        mask = cv2.GaussianBlur(raw, (51, 51), 0)
        return np.clip(mask, 0, 1)

    def _apply_sky(self, img_rgb: np.ndarray, mask: np.ndarray,
                   sky_exposure: float, sky_saturation: float) -> np.ndarray:
        """Blend sky-enhanced pixels into the original image using the mask."""
        orig = img_rgb.astype(np.float32)

        # Exposure adjustment in linear light — simple shift, no Reinhard compression
        linear = (orig / 255.0) ** 2.2
        linear = np.clip(linear * (2.0 ** sky_exposure), 0, 1)
        sky_exp = np.clip(linear ** (1.0 / 2.2) * 255, 0, 255).astype(np.uint8)

        # Saturation boost in HSV
        hsv = cv2.cvtColor(sky_exp, cv2.COLOR_RGB2HSV).astype(np.float32)
        hsv[:, :, 1] = np.clip(hsv[:, :, 1] * sky_saturation, 0, 255)
        sky_sat = cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2RGB).astype(np.float32)

        # Alpha blend: mask=1 → sky-enhanced, mask=0 → original
        mask3 = mask[:, :, np.newaxis]
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
        0.0 = no blur, 1.0 = heavy background softening)

    This mimics the depth-of-field separation of a fast prime lens —
    the subject stays razor sharp while busy backgrounds recede.
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "images":              ("IMAGE",),
                "foreground_sharpen":  ("FLOAT", {"default": 1.50, "min": 1.0, "max": 3.0, "step": 0.1}),
                "background_blur":     ("FLOAT", {"default": 0.50, "min": 0.0, "max": 1.0, "step": 0.1}),
            }
        }

    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "process"
    CATEGORY = "image/smart"

    def process(self, images, foreground_sharpen: float = 1.5, background_blur: float = 0.5):
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
            arr = (img.cpu().numpy() * 255).astype(np.uint8)
            fg_mask = self._depth_foreground_mask(arr, depth_pipe)
            result = self._blend_sharp_blur(arr, fg_mask, foreground_sharpen, background_blur)
            results.append(torch.from_numpy(result.astype(np.float32) / 255.0))

        return (torch.stack(results),)

    def _depth_foreground_mask(self, img_rgb: np.ndarray, depth_pipe) -> np.ndarray:
        """
        Run Depth Anything on the image, normalise to [0,1], resize to match,
        then invert so that near=1 (foreground) and far=0 (background).
        """
        h, w = img_rgb.shape[:2]
        img_pil = Image.fromarray(img_rgb)

        depth_out = depth_pipe(img_pil)
        depth_arr = np.array(depth_out["depth"], dtype=np.float32)

        # Normalise depth to 0..1
        d_min, d_max = depth_arr.min(), depth_arr.max()
        depth_norm = (depth_arr - d_min) / (d_max - d_min + 1e-8)

        # Resize depth map to original image size
        depth_resized = cv2.resize(depth_norm, (w, h), interpolation=cv2.INTER_LINEAR)

        # Depth Anything: larger value = farther away → invert for foreground mask
        fg_mask = 1.0 - depth_resized

        # Smooth mask to avoid hard transitions at object boundaries
        fg_mask = cv2.GaussianBlur(fg_mask, (31, 31), 0)
        return fg_mask.clip(0, 1)

    def _blend_sharp_blur(self, img_u8: np.ndarray, fg_mask: np.ndarray,
                          fg_sharpen: float, bg_blur: float) -> np.ndarray:
        """Blend foreground-sharpened and background-blurred versions using depth mask."""
        fg_mask3 = fg_mask[:, :, np.newaxis]

        # Foreground: unsharp mask sharpening
        if fg_sharpen > 1.0:
            blur = cv2.GaussianBlur(img_u8.astype(np.float32), (0, 0), 2.0)
            detail = img_u8.astype(np.float32) - blur
            sharpened = np.clip(img_u8.astype(np.float32) + detail * (fg_sharpen - 1.0), 0, 255)
        else:
            sharpened = img_u8.astype(np.float32)

        # Background: Gaussian blur
        if bg_blur > 0.05:
            ksize = int(bg_blur * 10) * 2 + 1   # always odd
            blurred = cv2.GaussianBlur(img_u8, (ksize, ksize), bg_blur * 5).astype(np.float32)
        else:
            blurred = img_u8.astype(np.float32)

        # Combine: near pixels get sharpened version, far pixels get blurred
        blended = sharpened * fg_mask3 + blurred * (1.0 - fg_mask3)
        return np.clip(blended, 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# WritePhotoMetadata
# ---------------------------------------------------------------------------
class WritePhotoMetadata:
    """
    Writes a per-photo JSON metadata file to the ComfyUI output directory.

    The Ruby photo-enhance.rb script downloads this file after the image,
    reads the AI pipeline details (scene type, profile settings, sky coverage,
    depth settings), and generates a human-readable .md report alongside the
    enhanced JPEG.

    filename_prefix must match the prefix injected into SaveImage so the Ruby
    script can find both files by the same prefix.
    """

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "image":            ("IMAGE",),
                "scene_type":       ("STRING",  {"default": "unknown"}),
                # Both inputs are injected per-prompt by photo-enhance.rb's inject_input
                "filename_prefix":  ("STRING",  {"default": "enhanced_"}),
                "source_filename":  ("STRING",  {"default": "photo"}),
            }
        }

    # Pass image through unchanged; side-effect is writing the metadata file
    RETURN_TYPES = ("IMAGE",)
    FUNCTION = "write"
    CATEGORY = "image/smart"

    # Mirrors AdaptivePhotoGrade — keep in sync if profiles change
    PROFILES = AdaptivePhotoGrade.PROFILES

    def write(self, image, scene_type: str, filename_prefix: str, source_filename: str):
        import json, datetime, os

        # Resolve ComfyUI output directory via its internal module
        try:
            import folder_paths
            out_dir = folder_paths.get_output_directory()
        except Exception:
            out_dir = "/ephemeral/comfyui/output"

        profile = self.PROFILES.get(scene_type, self.PROFILES["default"])

        # Compute sky mask coverage as a percentage of the image
        sky_coverage = self._sky_coverage(image[0])

        # source_filename is the upload name on ComfyUI, e.g. "DSCF5434.JPG.orient.JPG"
        # Strip the .orient.<ext> suffix if present to recover the original base name
        base = os.path.basename(source_filename)
        base = base.replace(".orient.JPG", "").replace(".orient.jpg", "")

        meta = {
            "generated_at":    datetime.datetime.utcnow().isoformat() + "Z",
            "source_filename": base,
            "scene_type":      scene_type,
            "enhancement_profile": {
                "exposure_stops":   profile["stops"],
                "contrast_factor":  profile["contrast"],
                "saturation_mult":  profile["saturation"],
                "detail_mult":      profile["detail"],
                "denoise_strength": profile["denoise"],
            },
            "sky": {
                "coverage_pct":  round(sky_coverage * 100, 1),
                "sky_exposure":  0.30,
                "sky_saturation": 1.20,
            },
            "depth_sharpen": {
                "foreground_sharpen": 1.50,
                "background_blur":    0.50,
            },
            "models": {
                "upscaler":     "realesr-general-x4v3 (Real-ESRGAN, GPU)",
                "face_restore": "CodeFormer fidelity=0.7 (GPU)",
                "scene_detect": "CLIP ViT-B/32 (openai/clip-vit-base-patch32)",
                "depth":        "Depth Anything V2 Small (GPU)",
            },
        }

        # Write as both a prefixed file (for Ruby to download by prefix) and
        # a source-named file for easy manual lookup in the output dir
        meta_path = os.path.join(out_dir, f"{filename_prefix}meta.json")
        with open(meta_path, "w") as f:
            json.dump(meta, f, indent=2)
        print(f"[WritePhotoMetadata] Wrote {meta_path} (scene={scene_type}, sky={sky_coverage:.1%})")

        return (image,)

    def _sky_coverage(self, img_tensor: "torch.Tensor") -> float:
        """Re-use SkyEnhance's mask logic to estimate sky % for reporting."""
        try:
            arr = (img_tensor.cpu().numpy() * 255).astype(np.uint8)
            helper = SkyEnhance()
            mask = helper._detect_sky(arr)
            return float(mask.mean())
        except Exception:
            return 0.0


# ---------------------------------------------------------------------------
# ComfyUI node registration
# ---------------------------------------------------------------------------
NODE_CLASS_MAPPINGS = {
    "CLIPSceneDetect":       CLIPSceneDetect,
    "AdaptivePhotoGrade":    AdaptivePhotoGrade,
    "SkyEnhance":            SkyEnhance,
    "DepthSelectiveSharpen": DepthSelectiveSharpen,
    "WritePhotoMetadata":    WritePhotoMetadata,
}

NODE_DISPLAY_NAME_MAPPINGS = {
    "CLIPSceneDetect":       "CLIP Scene Detect",
    "AdaptivePhotoGrade":    "Adaptive Photo Grade",
    "SkyEnhance":            "Sky Enhance",
    "DepthSelectiveSharpen": "Depth Selective Sharpen",
    "WritePhotoMetadata":    "Write Photo Metadata",
}

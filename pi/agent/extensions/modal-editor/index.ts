import { CustomEditor, type ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { matchesKey, truncateToWidth, visibleWidth } from "@mariozechner/pi-tui";

type Mode = "normal" | "insert";
type PendingAction = "g" | "d" | null;
type CharKind = "whitespace" | "word" | "punct";

type EditorStateAccess = {
	state: {
		lines: string[];
		cursorLine: number;
		cursorCol: number;
	};
	historyIndex: number;
	lastAction: string | null;
	preferredVisualCol: number | null;
	setCursorCol(col: number): void;
	pushUndoSnapshot(): void;
	undo(): void;
};

type Position = {
	line: number;
	col: number;
};

const NORMAL_KEYS: Record<string, string> = {
	h: "\x1b[D",
	j: "\x1b[B",
	k: "\x1b[A",
	l: "\x1b[C",
};

function isWordChar(char: string): boolean {
	return /[0-9A-Za-z_]/.test(char);
}

function charKind(char: string | null): CharKind {
	if (char === null || char === "\n" || /\s/.test(char)) return "whitespace";
	return isWordChar(char) ? "word" : "punct";
}

class ModalEditor extends CustomEditor {
	private mode: Mode = "normal";
	private pending: PendingAction = null;

	private internals(): EditorStateAccess {
		return this as unknown as EditorStateAccess;
	}

	private resetTransientState(): void {
		const editor = this.internals();
		editor.historyIndex = -1;
		editor.lastAction = null;
		editor.preferredVisualCol = null;
	}

	private setMode(mode: Mode): void {
		this.mode = mode;
		this.pending = null;
		this.tui.requestRender();
	}

	private lines(): string[] {
		return this.getLines();
	}

	private currentPosition(): Position {
		const cursor = this.getCursor();
		return { line: cursor.line, col: cursor.col };
	}

	private setPosition(position: Position): void {
		const editor = this.internals();
		editor.state.cursorLine = position.line;
		editor.setCursorCol(position.col);
		editor.preferredVisualCol = null;
		this.tui.requestRender();
	}

	private withUndo(change: () => void): void {
		const editor = this.internals();
		editor.pushUndoSnapshot();
		this.resetTransientState();
		change();
		this.onChange?.(this.getText());
		this.tui.requestRender();
	}

	private moveLeft(position: Position): Position {
		const lines = this.lines();
		if (position.col > 0) return { line: position.line, col: position.col - 1 };
		if (position.line > 0) {
			return {
				line: position.line - 1,
				col: (lines[position.line - 1] || "").length,
			};
		}
		return position;
	}

	private moveRight(position: Position): Position {
		const lines = this.lines();
		const line = lines[position.line] || "";
		if (position.col < line.length) return { line: position.line, col: position.col + 1 };
		if (position.line < lines.length - 1) return { line: position.line + 1, col: 0 };
		return position;
	}

	private charAt(position: Position): string | null {
		const lines = this.lines();
		const line = lines[position.line] || "";
		if (position.col < line.length) return line[position.col] || null;
		if (position.line < lines.length - 1) return "\n";
		return null;
	}

	private charBefore(position: Position): string | null {
		const lines = this.lines();
		if (position.col > 0) {
			const line = lines[position.line] || "";
			return line[position.col - 1] || null;
		}
		if (position.line > 0) return "\n";
		return null;
	}

	private moveLineStart(): void {
		const { line } = this.currentPosition();
		this.setPosition({ line, col: 0 });
	}

	private moveLineEnd(): void {
		const { line } = this.currentPosition();
		this.setPosition({ line, col: (this.lines()[line] || "").length });
	}

	private moveFileStart(): void {
		this.setPosition({ line: 0, col: 0 });
	}

	private moveFileEnd(): void {
		const lines = this.lines();
		const lastLine = Math.max(0, lines.length - 1);
		this.setPosition({ line: lastLine, col: (lines[lastLine] || "").length });
	}

	private moveWordBackwardPosition(from: Position): Position {
		let position = from;

		while (true) {
			const previous = this.charBefore(position);
			if (previous === null || charKind(previous) !== "whitespace") break;
			const next = this.moveLeft(position);
			if (next.line === position.line && next.col === position.col) break;
			position = next;
		}

		while (true) {
			const previous = this.charBefore(position);
			if (previous === null) break;
			const kind = charKind(previous);
			if (kind === "whitespace") break;
			const next = this.moveLeft(position);
			if (next.line === position.line && next.col === position.col) break;
			position = next;
			const beforeNext = this.charBefore(position);
			if (beforeNext === null || charKind(beforeNext) !== kind) break;
		}

		return position;
	}

	private moveWordForwardPosition(from: Position): Position {
		let position = from;
		let current = this.charAt(position);

		if (current !== null && charKind(current) !== "whitespace") {
			const kind = charKind(current);
			while (current !== null && charKind(current) === kind) {
				const next = this.moveRight(position);
				if (next.line === position.line && next.col === position.col) break;
				position = next;
				current = this.charAt(position);
			}
		}

		current = this.charAt(position);
		while (current !== null && charKind(current) === "whitespace") {
			const next = this.moveRight(position);
			if (next.line === position.line && next.col === position.col) break;
			position = next;
			current = this.charAt(position);
		}

		return position;
	}

	private moveWordEndPosition(from: Position): Position {
		let position = from;
		let current = this.charAt(position);

		while (current !== null && charKind(current) === "whitespace") {
			const next = this.moveRight(position);
			if (next.line === position.line && next.col === position.col) break;
			position = next;
			current = this.charAt(position);
		}

		if (current === null) return from;

		const kind = charKind(current);
		let last = position;

		while (current !== null && charKind(current) === kind) {
			last = position;
			const next = this.moveRight(position);
			if (next.line === position.line && next.col === position.col) break;
			position = next;
			current = this.charAt(position);
		}

		return last;
	}

	private moveWordBackward(): void {
		this.setPosition(this.moveWordBackwardPosition(this.currentPosition()));
	}

	private moveWordForward(): void {
		this.setPosition(this.moveWordForwardPosition(this.currentPosition()));
	}

	private moveWordEnd(): void {
		this.setPosition(this.moveWordEndPosition(this.currentPosition()));
	}

	private comparePositions(a: Position, b: Position): number {
		if (a.line !== b.line) return a.line - b.line;
		return a.col - b.col;
	}

	private nextPosition(position: Position): Position {
		return this.moveRight(position);
	}

	private deleteRange(start: Position, end: Position): void {
		if (this.comparePositions(start, end) >= 0) return;

		this.withUndo(() => {
			const editor = this.internals();
			const lines = [...editor.state.lines];

			if (start.line === end.line) {
				const line = lines[start.line] || "";
				lines[start.line] = line.slice(0, start.col) + line.slice(end.col);
			} else {
				const first = (lines[start.line] || "").slice(0, start.col);
				const last = (lines[end.line] || "").slice(end.col);
				lines.splice(start.line, end.line - start.line + 1, first + last);
			}

			editor.state.lines = lines.length > 0 ? lines : [""];
			editor.state.cursorLine = start.line;
			editor.setCursorCol(start.col);
		});
	}

	private deleteCurrentChar(): void {
		const start = this.currentPosition();
		const end = this.nextPosition(start);
		if (start.line === end.line && start.col === end.col) return;
		this.deleteRange(start, end);
	}

	private deleteToLineStart(): void {
		const cursor = this.currentPosition();
		this.deleteRange({ line: cursor.line, col: 0 }, cursor);
	}

	private deleteToLineEnd(): void {
		const cursor = this.currentPosition();
		this.deleteRange(cursor, { line: cursor.line, col: (this.lines()[cursor.line] || "").length });
	}

	private deleteWordBackward(): void {
		const cursor = this.currentPosition();
		this.deleteRange(this.moveWordBackwardPosition(cursor), cursor);
	}

	private deleteWordForward(): void {
		const cursor = this.currentPosition();
		this.deleteRange(cursor, this.moveWordForwardPosition(cursor));
	}

	private deleteToWordEnd(): void {
		const cursor = this.currentPosition();
		const end = this.nextPosition(this.moveWordEndPosition(cursor));
		this.deleteRange(cursor, end);
	}

	private deleteCurrentLine(): void {
		this.withUndo(() => {
			const editor = this.internals();
			const lines = [...editor.state.lines];
			const line = editor.state.cursorLine;

			if (lines.length === 1) {
				lines[0] = "";
				editor.state.lines = lines;
				editor.state.cursorLine = 0;
				editor.setCursorCol(0);
				return;
			}

			lines.splice(line, 1);
			const newLine = Math.min(line, lines.length - 1);
			editor.state.lines = lines;
			editor.state.cursorLine = newLine;
			editor.setCursorCol(Math.min(editor.state.cursorCol, (lines[newLine] || "").length));
		});
	}

	private openLineBelow(): void {
		this.withUndo(() => {
			const editor = this.internals();
			const lines = [...editor.state.lines];
			const line = editor.state.cursorLine;
			lines.splice(line + 1, 0, "");
			editor.state.lines = lines;
			editor.state.cursorLine = line + 1;
			editor.setCursorCol(0);
		});
		this.setMode("insert");
	}

	private openLineAbove(): void {
		this.withUndo(() => {
			const editor = this.internals();
			const lines = [...editor.state.lines];
			const line = editor.state.cursorLine;
			lines.splice(line, 0, "");
			editor.state.lines = lines;
			editor.state.cursorLine = line;
			editor.setCursorCol(0);
		});
		this.setMode("insert");
	}

	private handlePending(data: string): boolean {
		if (this.pending === "g") {
			this.pending = null;
			switch (data) {
				case "h":
				case "0":
					this.moveLineStart();
					return true;
				case "l":
				case "$":
					this.moveLineEnd();
					return true;
				case "g":
					this.moveFileStart();
					return true;
				case "e":
					this.moveFileEnd();
					return true;
				default:
					this.tui.requestRender();
					return data.length === 1;
			}
		}

		if (this.pending === "d") {
			this.pending = null;
			switch (data) {
				case "d":
					this.deleteCurrentLine();
					return true;
				case "w":
					this.deleteWordForward();
					return true;
				case "e":
					this.deleteToWordEnd();
					return true;
				case "b":
					this.deleteWordBackward();
					return true;
				case "0":
					this.deleteToLineStart();
					return true;
				case "$":
					this.deleteToLineEnd();
					return true;
				case "x":
					this.deleteCurrentChar();
					return true;
				default:
					this.tui.requestRender();
					return data.length === 1;
			}
		}

		return false;
	}

	private handleNormalMode(data: string): boolean {
		if (this.handlePending(data)) return true;

		if (data in NORMAL_KEYS) {
			super.handleInput(NORMAL_KEYS[data]!);
			return true;
		}

		switch (data) {
			case "i":
				this.setMode("insert");
				return true;
			case "a":
				super.handleInput("\x1b[C");
				this.setMode("insert");
				return true;
			case "I":
				this.moveLineStart();
				this.setMode("insert");
				return true;
			case "A":
				this.moveLineEnd();
				this.setMode("insert");
				return true;
			case "o":
				this.openLineBelow();
				return true;
			case "O":
				this.openLineAbove();
				return true;
			case "b":
				this.moveWordBackward();
				return true;
			case "w":
				this.moveWordForward();
				return true;
			case "e":
				this.moveWordEnd();
				return true;
			case "0":
				this.moveLineStart();
				return true;
			case "$":
				this.moveLineEnd();
				return true;
			case "D":
				this.deleteToLineEnd();
				return true;
			case "g":
			case "d":
				this.pending = data as PendingAction;
				this.tui.requestRender();
				return true;
			case "x":
				this.deleteCurrentChar();
				return true;
			case "u":
				this.internals().undo();
				this.tui.requestRender();
				return true;
			default:
				return false;
		}
	}

	handleInput(data: string): void {
		if (matchesKey(data, "escape")) {
			if (this.mode === "insert") {
				this.setMode("normal");
			} else {
				this.pending = null;
				super.handleInput(data);
			}
			return;
		}

		if (this.mode === "insert") {
			super.handleInput(data);
			return;
		}

		if (this.handleNormalMode(data)) return;

		if (data.length === 1 && data.charCodeAt(0) >= 32) return;
		super.handleInput(data);
	}

	render(width: number): string[] {
		const lines = super.render(width);
		if (lines.length === 0) return lines;

		const pendingLabel = this.pending ? ` ${this.pending}` : "";
		const label = this.mode === "normal" ? ` NORMAL${pendingLabel} ` : " INSERT ";
		const last = lines.length - 1;
		if (visibleWidth(lines[last]!) >= label.length) {
			lines[last] = truncateToWidth(lines[last]!, width - label.length, "") + label;
		}
		return lines;
	}
}

export default function (pi: ExtensionAPI) {
	pi.on("session_start", (_event, ctx) => {
		ctx.ui.setEditorComponent((tui, theme, kb) => new ModalEditor(tui, theme, kb));
	});
}

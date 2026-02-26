#!/usr/bin/env bash
# pre_consume.sh
#
# paperless-ngxのpre-consumeスクリプト。
# PDFをpdftoppmで画像に変換してndlocr-liteでOCRし、
# テキストをPDFに埋め込んでDOCUMENT_WORKING_PATHを上書きする。
#
# docker-compose.envに以下を追加:
#   PAPERLESS_PRE_CONSUME_SCRIPT=/usr/local/bin/pre_consume.sh
#   PAPERLESS_OCR_MODE=skip

set -euo pipefail

DOCUMENT_PATH="${DOCUMENT_WORKING_PATH:-}"

# DOCUMENT_WORKING_PATH が未設定なら終了
if [[ -z "$DOCUMENT_PATH" ]]; then
  echo "[ndlocr] DOCUMENT_WORKING_PATH が未設定のためスキップします" >&2
  exit 0
fi

# 拡張子を判定
ext="${DOCUMENT_PATH##*.}"
ext_lower="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"

# PDFのみndlocr-liteで処理、画像はpaperless-ngx標準OCR（Tesseract）に任せる
case "$ext_lower" in
  pdf) ;;
  *)
    echo "[ndlocr] PDF以外（${ext_lower}）はpaperless標準OCRに任せます" >&2
    exit 0
    ;;
esac

echo "[ndlocr] 処理開始: $(basename "$DOCUMENT_PATH")"

# ── 既存テキストチェック ──────────────────────────────────────
# テキスト埋め込み済みPDFはOCRをスキップする
existing_text="$(pdftotext "$DOCUMENT_PATH" - 2>/dev/null | tr -d '[:space:]')"
if [[ ${#existing_text} -ge 50 ]]; then
  echo "[ndlocr] テキスト埋め込み済み（${#existing_text}文字）のためOCRをスキップします" >&2
  exit 0
fi

# 作業ディレクトリ
WORK_DIR="$(mktemp -d /tmp/ndlocr_XXXXXX)"
IMG_DIR="${WORK_DIR}/images"
OCR_DIR="${WORK_DIR}/ocr_output"
mkdir -p "$IMG_DIR" "$OCR_DIR"

# 終了時に作業ディレクトリを削除
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Step 1: ファイル → 画像変換 ──────────────────────────────

if [[ "$ext_lower" == "pdf" ]]; then
  # ページ幅に応じてDPIを自動調整（目標出力幅: 8000px、範囲: 150〜300 DPI）
  # iPhoneスキャンPDF（ページが大きい）は低DPI、通常A4 PDFは300 DPIになる
  render_dpi=$(python3 - "$DOCUMENT_PATH" <<'PYEOF'
import sys
import fitz
doc = fitz.open(sys.argv[1])
page_width_pts = doc[0].rect.width if len(doc) > 0 else 595
dpi = 8000 * 72 / page_width_pts
dpi = max(150, min(300, int(dpi)))
print(dpi)
PYEOF
)
  echo "[ndlocr] レンダリングDPI: ${render_dpi}"
  pdftoppm -r "$render_dpi" -png "$DOCUMENT_PATH" "${IMG_DIR}/page"
  echo "[ndlocr] PDF→画像変換完了: $(ls "${IMG_DIR}" | wc -l)ページ"
else
  # 画像ファイルはそのままコピー
  cp "$DOCUMENT_PATH" "${IMG_DIR}/page-1.${ext_lower}"
  echo "[ndlocr] 画像ファイルをコピーしました"
fi

# ── Step 2: NDLOCR-Lite OCR実行 ──────────────────────────────

ndlocr-lite --sourcedir "$IMG_DIR" --output "$OCR_DIR"
echo "[ndlocr] OCR完了"

# ── Step 3: テキストファイルを連結 ──────────────────────────────
# ndlocr-liteは各ページごとに.txtファイルを出力するので、それを連結

TEXT_FILE="${WORK_DIR}/extracted.txt"

# .txtファイルをページ順にソートして連結
find "$OCR_DIR" -name "*.txt" -type f | sort | xargs cat > "$TEXT_FILE" 2>/dev/null || touch "$TEXT_FILE"

line_count=$(wc -l < "$TEXT_FILE")
echo "[ndlocr] テキスト抽出完了: ${line_count}行"

# ── Step 4: テキストをPDFに埋め込んでDOCUMENT_WORKING_PATHを上書き ──

# PDFでない場合（画像ファイル）はまずPDFに変換してから埋め込む
if [[ "$ext_lower" == "pdf" ]]; then
  BASE_PDF="$DOCUMENT_PATH"
else
  BASE_PDF="${WORK_DIR}/base.pdf"
  python3 - "$DOCUMENT_PATH" "$BASE_PDF" <<'PYEOF'
import sys
from PIL import Image as PilImage
img = PilImage.open(sys.argv[1]).convert("RGB")
img.save(sys.argv[2], "PDF", resolution=300)
PYEOF
fi

OUTPUT_PDF="${WORK_DIR}/output.pdf"

python3 - "$BASE_PDF" "$TEXT_FILE" "$OUTPUT_PDF" <<'PYEOF'
import sys
from pathlib import Path

try:
    import fitz  # pymupdf
except ImportError:
    import shutil
    shutil.copy2(sys.argv[1], sys.argv[3])
    print("[ndlocr] pymupdf未インストール: テキスト埋め込みをスキップ", file=sys.stderr)
    sys.exit(0)

lines = Path(sys.argv[2]).read_text(encoding="utf-8").split("\n")
doc = fitz.open(sys.argv[1])
n = len(doc)
lines_per_page = max(1, len(lines) // n) if n > 0 else 1
font = fitz.Font(fontfile="/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc")  # Noto CJK（ocrmypdf PDF/A変換後も文字化けしない）

for page_num, page in enumerate(doc):
    start = page_num * lines_per_page
    end = start + lines_per_page if page_num < n - 1 else len(lines)
    page_text = "\n".join(lines[start:end])
    if page_text.strip():
        tw = fitz.TextWriter(page.rect, color=(1, 1, 1))  # 白色・不可視
        try:
            tw.append((0, 12), page_text, font=font, fontsize=1)
        except Exception as e:
            print(f"[ndlocr] テキスト埋め込み警告: {e}", file=sys.stderr)
        tw.write_text(page)

doc.save(sys.argv[3])
doc.close()
print("[ndlocr] テキストレイヤー付きPDF生成完了", file=sys.stderr)
PYEOF

# DOCUMENT_WORKING_PATHをOCR済みPDFで上書き
cp "$OUTPUT_PDF" "$DOCUMENT_PATH"

echo "[ndlocr] 完了: $(basename "$DOCUMENT_PATH")"
exit 0

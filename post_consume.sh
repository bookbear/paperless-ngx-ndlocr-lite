#!/usr/bin/env bash
# post_consume.sh
#
# paperless-ngxのpost-consumeスクリプト。
# 画像ファイルの場合、ndlocr-liteでOCRし直してcontentを更新する。
#
# docker-compose.envに以下を追加:
#   PAPERLESS_POST_CONSUME_SCRIPT=/usr/local/bin/post_consume.sh

set -euo pipefail

DOCUMENT_ID="${DOCUMENT_ID:-}"
SOURCE_PATH="${DOCUMENT_SOURCE_PATH:-}"

# 必須変数チェック
if [[ -z "$DOCUMENT_ID" ]] || [[ -z "$SOURCE_PATH" ]]; then
  echo "[ndlocr-post] DOCUMENT_IDまたはSOURCE_PATHが未設定のためスキップ" >&2
  exit 0
fi

# 拡張子を判定
ext="${SOURCE_PATH##*.}"
ext_lower="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"

# 画像ファイル以外はスキップ（PDFはpre_consume.shで処理済み）
case "$ext_lower" in
  png|jpg|jpeg|tiff|tif|bmp|gif|webp|jp2) ;;
  *)
    echo "[ndlocr-post] 画像以外（${ext_lower}）のためスキップ" >&2
    exit 0
    ;;
esac

echo "[ndlocr-post] 処理開始: Document ID=${DOCUMENT_ID}, $(basename "$SOURCE_PATH")"

# 作業ディレクトリ
WORK_DIR="$(mktemp -d /tmp/ndlocr_post_XXXXXX)"
IMG_DIR="${WORK_DIR}/images"
OCR_DIR="${WORK_DIR}/ocr_output"
mkdir -p "$IMG_DIR" "$OCR_DIR"

# 終了時に作業ディレクトリを削除
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Step 1: 画像をコピー ──────────────────────────────

cp "$SOURCE_PATH" "${IMG_DIR}/page-1.${ext_lower}"
echo "[ndlocr-post] 画像ファイルをコピーしました"

# ── Step 2: NDLOCR-Lite OCR実行 ──────────────────────────────

ndlocr-lite --sourcedir "$IMG_DIR" --output "$OCR_DIR"
echo "[ndlocr-post] OCR完了"

# ── Step 3: テキストファイルを連結 ──────────────────────────────

TEXT_FILE="${WORK_DIR}/extracted.txt"
find "$OCR_DIR" -name "*.txt" -type f | sort | xargs cat > "$TEXT_FILE" 2>/dev/null || touch "$TEXT_FILE"

line_count=$(wc -l < "$TEXT_FILE")
echo "[ndlocr-post] テキスト抽出完了: ${line_count}行"

# ── Step 4: ドキュメントのcontentを更新 ──────────────────────────────

python3 /usr/src/paperless/src/manage.py shell <<PYEOF
import sys
from pathlib import Path
from documents.models import Document

doc_id = ${DOCUMENT_ID}
text_file = Path("${TEXT_FILE}")

try:
    doc = Document.objects.get(id=doc_id)
    new_content = text_file.read_text(encoding="utf-8").strip()

    if new_content:
        doc.content = new_content
        doc.save(update_fields=["content"])
        print(f"[ndlocr-post] Document {doc_id} のcontentを更新しました（{len(new_content)}文字）", file=sys.stderr)
    else:
        print(f"[ndlocr-post] OCR結果が空のため更新をスキップ", file=sys.stderr)
except Document.DoesNotExist:
    print(f"[ndlocr-post] Document {doc_id} が見つかりません", file=sys.stderr)
except Exception as e:
    print(f"[ndlocr-post] エラー: {e}", file=sys.stderr)
PYEOF

echo "[ndlocr-post] 完了: Document ID=${DOCUMENT_ID}"
exit 0

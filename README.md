# paperless-ngx + ndlocr-lite カスタム構成

paperless-ngxで日本語OCRエンジン「ndlocr-lite」を使用するためのカスタム構成。

## 概要

paperless-ngx標準のTesseract OCRに代わり、国立国会図書館が開発した日本語OCRエンジン「ndlocr-lite」を使用して、より高精度な日本語テキスト抽出を実現する。

## 処理フロー

### PDFファイルの場合

```
PDF → pre_consume.sh → ndlocr-lite OCR → テキストをPDFに埋め込み → paperless-ngx取り込み
```

- `pre_consume.sh`でndlocr-liteを使用してOCR処理
- 抽出したテキストをPDFに埋め込み（pymupdf使用）
- paperless-ngxのOCRはスキップ（`PAPERLESS_OCR_MODE=skip`）
- PDFビューアでテキスト選択・コピー可能

### 画像ファイルの場合（JPG, PNG等）

```
画像 → paperless-ngx取り込み（Tesseract OCR） → post_consume.sh → ndlocr-lite OCR → content上書き
```

- 画像は一旦paperless-ngx標準のTesseract OCRで処理
- 取り込み完了後、`post_consume.sh`でndlocr-liteを使用してOCRし直し
- ドキュメントのcontentフィールドを上書き更新
- paperless-ngx内での検索はndlocr-liteの結果が使用される

`post_consume.sh`を使う理由：pre_consumeで画像をOCR処理しようとすると、テキスト埋め込みのためにPDFに変換して返すことになる。しかしpaperless-ngxはpre_consume後も元のファイル種別（画像）が返ってくることを前提にしているため、PDFが返ってく
るとエラーになる。そのため、取り込み完了後にpost_consumeでDjango ORMを通じて`content`フィールドだけ上書きする方式を採用している。

## ファイル構成

```
paperless-ngx/
├── Dockerfile              # カスタムイメージ定義
├── docker-compose.yml      # Docker Compose設定
├── docker-compose.env      # 環境変数設定
├── pre_consume.sh          # PDF用OCR処理スクリプト
├── post_consume.sh         # 画像用OCR処理スクリプト
├── consume/                # ドキュメント取り込みディレクトリ
└── export/                 # エクスポートディレクトリ
```

## 主要コンポーネント

### Dockerfile

- ベースイメージ: `ghcr.io/paperless-ngx/paperless-ngx:latest`
- 追加パッケージ:
  - `poppler-utils` - PDF→画像変換（pdftoppm）
  - `ndlocr-lite` - 日本語OCRエンジン
  - `pymupdf` - PDFテキスト埋め込み
  - `pypdfium2` - PDF処理

### pre_consume.sh

PDFファイル専用のpre-consumeスクリプト。

1. PDFを画像に変換（pdftoppm, 300dpi）
2. ndlocr-liteでOCR実行
3. 抽出テキストをPDFに埋め込み（pymupdf）
4. 元のPDFを上書き

### post_consume.sh

画像ファイル専用のpost-consumeスクリプト。

1. 取り込み済みドキュメントの元画像を取得
2. ndlocr-liteでOCR実行
3. ドキュメントのcontentフィールドを更新

### docker-compose.env

```env
PAPERLESS_TIME_ZONE=Asia/Tokyo
PAPERLESS_OCR_LANGUAGES=jpn jpn-vert
PAPERLESS_OCR_DESKEW=1
PAPERLESS_PRE_CONSUME_SCRIPT=/usr/local/bin/pre_consume.sh
PAPERLESS_POST_CONSUME_SCRIPT=/usr/local/bin/post_consume.sh
PAPERLESS_OCR_MODE=skip
```

`PAPERLESS_OCR_MODE=skip`の意味：テキストが既に存在するページのOCRをスキップし、テキストのないページのみOCRを実行する。

- PDFはpre_consume.shでテキストを埋め込み済みのため、Tesseract OCRがスキップされndlocr-liteの結果が保持される
- 画像はテキストがないためTesseract OCRが実行されるが、その後post_consume.shがndlocr-liteの結果で`content`フィールドを上書きする

## 使い方

### ビルド・起動

```bash
docker compose build
docker compose up -d
```

### ドキュメント取り込み

`consume/`ディレクトリにPDFまたは画像ファイルを配置すると、自動的に処理される。

### ログ確認

```bash
docker compose logs -f webserver
```

### 抽出テキスト確認

```bash
docker compose exec webserver python3 /usr/src/paperless/src/manage.py shell -c "
from documents.models import Document
doc = Document.objects.get(id=<DOCUMENT_ID>)
print(doc.content)
"
```

## 対応ファイル形式

| 形式 | 処理方法 | テキスト埋め込み |
|------|----------|-----------------|
| PDF | pre_consume.sh | あり（PDF内） |
| JPG/JPEG | post_consume.sh | なし（contentのみ） |
| PNG | post_consume.sh | なし（contentのみ） |
| TIFF/TIF | post_consume.sh | なし（contentのみ） |
| BMP | post_consume.sh | なし（contentのみ） |
| GIF | post_consume.sh | なし（contentのみ） |
| WebP | post_consume.sh | なし（contentのみ） |
| その他 | paperless-ngx標準 | - |

## 注意事項

- ndlocr-liteは日本語に特化したOCRエンジンのため、英語等の他言語ドキュメントには標準のTesseractの方が適している場合がある
- 画像ファイルの場合、PDFにはTesseract版のテキストが埋め込まれるが、paperless-ngx内の検索はndlocr-lite版が使用される
- 大きな画像ファイルの処理には時間がかかる場合がある

## 参考リンク

- [paperless-ngx](https://github.com/paperless-ngx/paperless-ngx)
- [ndlocr-lite](https://github.com/ndl-lab/ndlocr-lite)
- [pymupdf](https://pymupdf.readthedocs.io/)

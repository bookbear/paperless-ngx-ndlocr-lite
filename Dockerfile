# paperless-ngxにNDLOCR-Liteを同梱したカスタムイメージ
FROM ghcr.io/paperless-ngx/paperless-ngx:latest

ARG DEBIAN_FRONTEND=noninteractive

# poppler-utils (pdftoppm) と日本語フォントをインストール
# fonts-noto-cjk: ocrmypdf PDF/A変換後もCJK文字が化けないフォント
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        poppler-utils \
        git \
        fonts-noto-cjk \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ndlocr-liteをpipでシステムワイドにインストール
# paperlessユーザー（UID 1000）からもアクセス可能
RUN git clone https://github.com/ndl-lab/ndlocr-lite /opt/ndlocr-lite \
    && pip install --no-cache-dir /opt/ndlocr-lite pypdfium2 pymupdf \
    && rm -rf /opt/ndlocr-lite

# pre_consume.sh をコンテナに配置
COPY pre_consume.sh /usr/local/bin/pre_consume.sh
RUN chmod +x /usr/local/bin/pre_consume.sh

# post_consume.sh をコンテナに配置
COPY post_consume.sh /usr/local/bin/post_consume.sh
RUN chmod +x /usr/local/bin/post_consume.sh

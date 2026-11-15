# 启强汽车 App（iOS 未签名 ipa）

WebView 壳，加载 https://gw.pricc.fun:8443/keytop

## 出包
GitHub Actions（macos-15）自动构建未签名 ipa，见 `.github/workflows/build-ipa.yml`。
产物在 Actions 页面的 Artifacts 里下载。

## 签名安装
用 Sideloadly / AltStore 自签安装（普通 Apple ID 即可，7 天续签一次）。

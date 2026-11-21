# VidDL
iOS video downloader. Source in `ios/`. GitHub Actions (`.github/workflows/build.yml`) builds `VidDL.ipa`,
rootful (`iphoneos-arm`) and rootless (`iphoneos-arm64`) `.deb` packages, and publishes a Sileo repo to GitHub Pages.

Setup once: repo Settings → Pages → Source: **GitHub Actions**. Then run the workflow (Actions tab).
Sileo source URL: `https://<your-username>.github.io/<repo-name>/`

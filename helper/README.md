# PackageManager helper

v1.2 使用 root `app_process` 執行 Java helper，透過 Android framework 讀取每位使用者的套件與元件狀態、修改明確 profiles 中的目標，並驗證修改及還原結果。入口類別為 `dev.lokey.otablocker.Main`，repository 中的原始碼位於 `helper/src/dev/lokey/otablocker/Main.java`，模組 ZIP 攜帶的建置產物為 `helper/classes.dex`。

helper 的設計目標是 Android 8.0／API 26 以上；framework／隱藏 API 在不同 Android 版本可能有差異，最低目標版本不等於所有 ROM 均已驗證。

目前建置腳本適用 Windows PowerShell，需要 JDK 與 Android SDK 的 `android.jar`、`d8`。預設使用 SDK Platform `android-36`、Build Tools `36.0.0`；這是建置工具版本，不是裝置最低 Android 版本。在 repository 根目錄執行：

```powershell
.\scripts\build.ps1
# 非預設安裝位置時，可明確指定：
.\scripts\build.ps1 -SdkRoot 'C:\path\to\Android\Sdk' -JavaHome 'C:\path\to\jdk-17' -Platform 'android-36' -BuildTools '36.0.0'
```

腳本會先編譯原始碼、以 D8 產生最低 API 26 的 DEX，再建立模組 ZIP。helper 應從 repository 中的完整原始碼建置，不下載不明來源的預編譯檔案。腳本預設搜尋本機 SDK 與 JDK 17／21；實際可用環境由腳本驗證。

執行請使用模組根目錄的 `cli.sh`，避免跳過共用操作鎖與暫停控制直接呼叫 helper。狀態資料位於 `/data/adb/fuckotaupdate`，應只允許 root 存取。Shell 入口和 Java helper 均不應保存 GitHub 憑證。

profiles 的詳細格式、支援判定與 OEM 適配驗收見 [README](../README.md)。

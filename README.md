# Fuck OTA Update

一個以 Magisk `service.sh` 運作的 Pixel OTA 阻擋模組。它會停用 Google Play 服務與 Setup Wizard 的 Android 系統 OTA 入口、對每個 Android 使用者移除 Factory OTA 套件，並在 Play 服務更新後自動重新套用停用狀態。

目前版本：`v1.1`（`versionCode=11`）

## 功能

- 停用目前 Pixel／Google Play 服務中的 OTA Activity、Service、JobService、Provider 與 Resume-on-Reboot 元件。
- 保留舊版 GMS／GSF 元件清單；不存在的舊元件會安靜略過，不再產生大量 Java 例外紀錄。
- 停用 Setup Wizard 的 OTA、Early Update 與 Complete In-Flight Updates 入口。
- 對所有現有 Android 使用者執行 `pm uninstall -k --user`，隱藏 `com.google.android.factoryota`。
- 每 15 秒比對 Play 服務等套件的 APK 路徑。套件被更新／替換後，等待 5 秒讓 PackageManager 穩定，再更新元件清單並重新停用。
- 每 5 分鐘重新套用一次，修復沒有更換 APK、但元件狀態被其他程序重設的情況。
- 每次套用都重新讀取使用者清單，因此之後新增的次要使用者／工作設定檔也會納入。
- Magisk 模組頁面的「動作」按鈕可立即重新掃描、套用並顯示成功／略過／失敗數量。
- 紀錄檔超過 100 KiB 時會自動保留最近約 300 行。
- 移除模組時把元件設回 APK 宣告的 `default-state`，並為各使用者還原 Factory OTA 系統套件。

## 阻擋範圍

本模組阻擋 Pixel 線上 Android 系統 OTA 的使用者介面、排程、下載／安裝協調入口與 Setup Wizard OTA 流程。主要涵蓋：

- `com.google.android.gms/.update.*`
- `com.google.android.gsf/.update.*`（舊版相容）
- `com.google.android.setupwizard/.update.*`
- `com.google.android.factoryota`

它不會停用整個 Google Play 服務，也不會阻止 Play 商店更新 Google Play 服務；更新完成後，常駐服務會自動把 OTA 元件停用回去。

它不攔截 recovery／ADB sideload／fastboot 等手動刷機，也不保證回滾已經寫入另一個 slot、只差重新開機的 OTA。Google Play 系統更新（Mainline/APEX）與一般 Play 商店 App 更新也不在此模組的主要阻擋範圍。

## 安裝

需求：

- 已解鎖並安裝 Magisk 的 Pixel 裝置
- Magisk 20.4 或更新版本

在 Magisk App 中選擇「模組」→「從儲存空間安裝」，選取 `FuckOTAUpdate.zip`，安裝完成後重新開機。

也可用 ADB 安裝：

```sh
adb push FuckOTAUpdate.zip /data/local/tmp/FuckOTAUpdate.zip
adb shell "su -c 'magisk --install-module /data/local/tmp/FuckOTAUpdate.zip'"
adb reboot
```

## 線上更新

`module.prop` 會從 `main` 分支讀取更新資訊：

```text
https://raw.githubusercontent.com/lokey0905/FuckOTAUpdate/main/update.json
```

`update.json` 內的模組下載網址指向最新 GitHub Release 的同名附件：

```text
https://github.com/lokey0905/FuckOTAUpdate/releases/latest/download/FuckOTAUpdate.zip
```

發布新版時：

1. 同步提高 `module.prop` 與 `update.json` 的 `version`／`versionCode`。
2. 更新 `CHANGELOG.md` 並重新建立 `FuckOTAUpdate.zip`。
3. 建立新的 GitHub Release，並上傳檔名完全相同的 `FuckOTAUpdate.zip`。
4. 確認 Release 附件網址可下載後，再把新版 `update.json` 推送到 `main`。

GitHub 儲存庫及 Release 必須可供未登入的裝置公開下載；private repository 的 Release 仍需要 GitHub 驗證，Magisk 無法直接使用。

## 立即套用與檢查

可按 Magisk 模組頁面的「動作」按鈕，或執行：

```sh
adb shell "su -c 'sh /data/adb/modules/FuckOTAUpdate/action.sh'"
```

成功時會看到類似結果：

```text
Result: OK
Users: 0
Disabled existing components: 18
Unavailable/legacy targets skipped: 8
Failures: 0
```

`Unavailable/legacy targets skipped` 不是錯誤，代表目前 ROM／Play 服務版本沒有那些舊元件。判斷是否成功請以 `Failures: 0` 為準。

確認系統更新 Intent 已無可用 Activity：

```sh
adb shell "cmd package resolve-activity --brief --user 0 -a android.settings.SYSTEM_UPDATE_SETTINGS"
```

預期輸出：

```text
No activity found
```

確認 Factory OTA 已針對使用者 0 移除：

```sh
adb shell "pm list packages --user 0 com.google.android.factoryota"
```

預期沒有輸出。

## 確認 Play 服務更新後有自動修復

先記下目前 APK 路徑：

```sh
adb shell "pm path com.google.android.gms | head -n 1"
```

Play 服務更新完成後再次執行；通常 `/data/app/.../base.apk` 路徑會改變。接著檢查模組紀錄：

```sh
adb shell "su -c 'grep reason=package-replaced /data/adb/modules/FuckOTAUpdate/disable_ota.log | tail -n 5'"
```

出現 `reason=package-replaced` 且同一行為 `failed=0`，代表模組已偵測套件替換並重新套用。PackageManager 正常完成替換時通常會在約 5–20 秒內處理；若安裝階段持續較久，路徑再次變動時還會重試。即使路徑沒有改變，5 分鐘週期檢查仍會修復狀態。

## 紀錄與除錯

```sh
adb shell "su -c 'tail -n 100 /data/adb/modules/FuckOTAUpdate/disable_ota.log'"
adb shell "su -c 'ps -A -o PID,PPID,USER,ARGS | grep /data/adb/modules/FuckOTAUpdate/service.sh'"
```

紀錄中的欄位：

- `reason=boot`：開機後首次套用。
- `reason=package-replaced`：偵測到 GMS／GSF／Setup Wizard APK 路徑改變。
- `reason=periodic`：定期修復與每小時健康紀錄。
- `disabled`：這一輪成功停用的現有元件數。
- `missing`：目前版本不存在的相容性目標數。
- `failed`：真正的停用失敗數；正常應為 `0`。
- `factoryota_removed`：這一輪新移除的使用者安裝數；先前已移除時為 `0` 是正常現象。

## 移除與還原

在 Magisk 中移除模組並重新開機。`uninstall.sh` 會：

1. 將所有已知及動態發現的 OTA 元件恢復成 APK 預設狀態。
2. 對各使用者執行 `install-existing`，還原 Factory OTA 系統套件。

若只想暫時允許 OTA，建議移除／停用模組並重新開機，不要逐一強制 `pm enable`，因為部分元件在原廠 APK 中本來就是預設停用。

## 參考

- [Magisk Developer Guides — Modules and Boot Scripts](https://github.com/topjohnwu/Magisk/blob/master/docs/guides.md)
- [AOSP PackageManagerShellCommand](https://android.googlesource.com/platform/frameworks/base/+/master/services/core/java/com/android/server/pm/PackageManagerShellCommand.java)

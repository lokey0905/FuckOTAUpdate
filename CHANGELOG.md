# Changelog

## v1.2

- 適用範圍明確調整為「透過 Google Play 服務處理系統 OTA 的裝置」，不再只以 Pixel 品牌判斷支援。
- 加入 root `app_process` helper，以 PackageManager 查詢實際元件及 enabled state；停用後回讀驗證，不再把零失敗或所有目標不存在視為成功。
- 加入持久化原始狀態紀錄、暫停／還原／恢復操作，以及共用操作鎖；只還原本模組管理的項目，不強制啟用原本已停用的元件。
- 改善套件更新期間的重試與週期驗證，只修正狀態差異；移除整包 `force-stop`。
- 卸載改用持久 runtime 與專屬一次性開機腳本延後還原，避免同步等待開機及模組目錄刪除造成的還原缺漏。
- 明確 allowlist profiles 取代命名空間自動停用，保留未來 OEM 適配介面；預設只啟用 GMS／舊版 GSF。OEM 擴充需新增並審查 profile，不會依品牌自動套用未知規則。
- Setup Wizard 與 Factory OTA 改為選用，Factory OTA 改採可逆的 per-user 停用，不再移除套件。
- 加入 `status`、`diagnose`、`apply`、`restore`、`resume` CLI；補充 v1.1 升級基準限制、驗收範圍及 REST API 發版流程。
- 補充 Nothing A142／SukiSU 與 Nothing Phone (4a) A069／Magisk Kitsune 的驗證結果；不將其他 Pixel、真實 GMS 升級或所有重開機情境視為已驗證。
- 明確說明獨立 ART／Mainline 更新不是阻擋範圍。

## v1.1

- 加入 Magisk 線上更新功能。
- 新增 `update.json` 與遠端更新紀錄。
- 改用 GitHub Releases 的 `FuckOTAUpdate.zip` 作為更新包，避免在 Git 儲存庫中追蹤建置產物。

## v1.0

- 補齊新版 Google Play 服務的 Pixel OTA 元件。
- 加入 Setup Wizard OTA 元件與舊版 GMS／GSF 相容目標。
- Play 服務 APK 被替換後自動重新掃描並停用 OTA 元件。
- 保留 v0.4 已有的 5 分鐘週期重套用，加入 Magisk 動作按鈕、結果統計與擴充的卸載恢復流程；此時仍未保存精確原始狀態。

## v0.4-component-disable-fix

- 元件停用使用 `pm disable --user`，檢查輸出並提供備援命令。
- 包含 10 個 GMS／GSF OTA 靜態目標，已有多使用者處理與 5 分鐘背景重套用。
- 當時仍會移除各使用者的 Factory OTA、視前景更新頁執行 GMS／GSF 整包 force-stop；卸載恢復為預設狀態而非保存的原始狀態。v1.2 已調整這些行為。

# Fuck OTA Update

針對**透過 Google Play 服務處理 Android 系統 OTA** 的裝置，停用已確認的 OTA 元件，並在套件更新或元件狀態被重設後重新套用。目標包含使用這條更新路徑的 Pixel、Nothing 等裝置；品牌名稱本身不是相容性保證。

目前原始碼版本：`v1.2`（`versionCode=12`）。原始碼版本與 GitHub 最新 Release 可能不同，安裝前請核對 Release 的版號。

## 阻擋範圍與限制

- 預設只套用 `gms` 與 `gsf` 的明確元件清單；不存在的舊版元件會略過。
- Setup Wizard 與 Factory OTA 改為選用 profile，預設不啟用。
- 不停用整個 Google Play 服務、不對 GMS／GSF 執行 `force-stop`；一般 Play 商店 App 更新不是阻擋目標。
- 不覆蓋或替換 `update_engine`，不操作 slot、Virtual A/B snapshots、取消更新或重設更新引擎狀態。
- 不攔截 recovery、ADB sideload 或 fastboot 刷機；不能保證取消已經交給更新引擎的更新，尤其是已寫入另一個 slot 或正在合併 snapshots 的更新。
- Google Play 系統更新（Mainline/APEX，包含獨立發送的 ART 更新）與 OEM 自有 OTA 路徑尚不在預設適配範圍。本模組不刪除或回滾 ART APEX；`RESULT=blocked` 不代表 ART 更新也被阻擋。

這是預防新 OTA 發起的元件控制，不是對所有 Android 更新路徑的封鎖保證。既有 GMS OTA 工作或已開啟的更新頁面不會因修改元件設定立即終止。輪詢仍存在時間窗；套件更新後、服務完成修復前，元件可能短暫恢復啟用。

## v1.2 的可靠性調整

- 列舉 Android 使用者，再以 root `app_process` helper 逐使用者讀取 PackageManager 的套件及元件狀態，依明確清單處理，不再以 `.update.*` 字串掃描直接擴大停用範圍。
- 在嘗試修改目標前，先持久保存該使用者、該目標的原始 enabled state；還原時使用紀錄中的狀態，不一律強制啟用或設回 default。若呼叫結果不明，仍保留紀錄供後續還原，不能因回報錯誤就假設沒有修改。
- 每次只修正狀態差異，並重新讀取結果驗證；「沒有失敗」或「所有目標都不存在」不再等同阻擋成功。
- 套件替換、查詢暫時失敗或套用未完成時保留待處理狀態，重試到成功驗證；不把失敗掃描當成已完成。套件變動以 PackageManager 狀態檔的中繼資料判定，避免每輪逐套件呼叫查詢。
- Service、Action、CLI 與還原操作共用核心 `flock` 鎖，程序結束即釋放；還原先暫停背景套用，避免剛恢復又被停用。
- 卸載不在早期開機同步等待 Android 完成啟動；必要的還原 runtime 與狀態留在持久目錄，由專屬一次性開機腳本延後還原。

## 安裝

需要 root、可執行模組開機腳本的管理器、支援 `flock` 的管理器 BusyBox 或系統工具，以及 Android 8.0／API 26 以上。Android 版本是 helper 的最低目標，並不表示所有該版本以上的 ROM 都已驗證相容。

生命週期設計涵蓋 Magisk、KernelSU／SukiSU；Magisk 安裝入口要求 20.4 以上，各管理器與 ROM 的實際相容性仍以測試結果為準。請先完成裝置初始設定，再從 root 管理器安裝 `FuckOTAUpdate.zip` 並重新開機。安裝前應確認沒有正在進行的 OTA 安裝或 snapshot 合併。

原始碼中的 helper 必須先建置為 `helper/classes.dex` 才能打包。建置說明見 [helper/README.md](helper/README.md)。ZIP 不應再被 Git 追蹤。

## 操作與狀態

以下命令在裝置 root shell 執行；也可由 `adb shell` 進入後執行 `su`：

```sh
sh /data/adb/modules/FuckOTAUpdate/cli.sh status
sh /data/adb/modules/FuckOTAUpdate/cli.sh diagnose
sh /data/adb/modules/FuckOTAUpdate/cli.sh apply
sh /data/adb/modules/FuckOTAUpdate/cli.sh restore
sh /data/adb/modules/FuckOTAUpdate/cli.sh resume
```

| 操作 | 用途 |
| --- | --- |
| `status` | 查詢目前阻擋狀態，不修改 PackageManager 設定。 |
| `diagnose` | 列出逐使用者的套件、核心目標及元件狀態；額外列出 `.update.*` 元件供人工審查，不會自動停用未列入清單的項目。 |
| `apply` | 套用一次並驗證；若先前已還原並暫停，不會自行解除暫停。 |
| `restore` | 先暫停背景套用，再還原本模組已記錄的原始狀態。 |
| `resume` | 明確解除暫停，重新套用並恢復背景保護。 |

模組管理器的「動作」按鈕會執行套用並顯示狀態；已暫停時請使用 `resume` 恢復保護。

狀態判定同時考慮核心目標是否存在，以及所有已發現且納入管理的目標是否成功停用。每位使用者至少必須存在一個已選 profile 的 `core` 目標，才具備已知更新路徑的支援證據。全部核心目標都不存在時，應視為不支援，不能因失敗數為零就認為 OTA 已阻擋；部分失敗或暫時無法查詢也不能視為完成。

| `RESULT` | 意義 |
| --- | --- |
| `blocked` | 本次查詢找到已知核心能力，且納入檢查的現有目標均為明確停用狀態。 |
| `degraded` | 目標尚未全部停用、部分使用者缺少核心能力，或套用／還原尚有待處理項目。 |
| `unsupported` | 沒有找到已選 profiles 的核心能力，不能宣稱支援或阻擋成功。 |
| `error` | 設定、框架查詢或其他操作發生錯誤。 |
| `restored` | 紀錄中的待還原項目均已完成驗證。 |

`status`／`diagnose` 的 `MODE` 與 `RESULT` 分開看：`MODE=active` 表示服務允許套用，並不等於目標已驗證；`MODE=restored` 也不保證所有目標都啟用，因為使用者原本就可能停用它們。`RESULT=blocked` 僅涵蓋明確清單，不能證明未知的新 OTA 元件或其他更新路徑不存在。

可另外在 root shell 查詢更新 Intent 作為佐證：

```sh
cmd package resolve-activity --brief --user 0 -a android.settings.SYSTEM_UPDATE_SETTINGS
```

不同 ROM 可能仍有設定頁入口，因此「有／沒有 Activity」都不能單獨證明底層更新已被阻擋。

## 設定與選用 profile

設定檔為 `/data/adb/fuckotaupdate/config.conf`。持久資料位於 `/data/adb/fuckotaupdate`，與 `/data/adb/modules/FuckOTAUpdate` 分離，模組升級時會保留原始狀態紀錄。

預設設定：

```ini
ENABLED_PROFILES=gms,gsf
CHECK_INTERVAL=15
REAPPLY_INTERVAL=300
MAX_RETRY=60
```

`CHECK_INTERVAL` 是套件狀態檔中繼資料的變動偵測間隔（允許 5–300）；`REAPPLY_INTERVAL` 是完整週期驗證與修復間隔（允許 30–86400）；`MAX_RETRY` 限制暫時失敗後從 5 秒開始的指數退避間隔（允許 5–60）。時間單位為秒，並非保證的更新阻擋延遲。設定檔只作為資料解析；未知鍵值或不合法數值會拒絕套用，不會當成 Shell 腳本執行。還原依原始狀態紀錄進行，不因目前設定檔寫錯而受阻。

| Profile | 預設 | 範圍 |
| --- | --- | --- |
| `gms` | 啟用 | 已確認的 Google Play 服務系統 OTA 元件。 |
| `gsf` | 啟用 | 舊版 Google Services Framework OTA；不存在時略過。 |
| `setupwizard` | 停用 | 明確列出的舊版設定精靈 OTA 入口。 |
| `factory-ota` | 停用 | 對每位使用者可逆地停用 Factory OTA 套件，不移除套件。 |

啟用 `setupwizard` 前需確認 ROM 中各元件用途與裝置已完成初始設定。新版 `CheckPlayEarlyUpdate*` 用途尚未確認，因此未自動納入。

變更已啟用的 profiles 前，請依序 `restore` → 修改設定 → `resume`。直接刪除 profile 名稱不會自動撤銷舊 profile 已做過的修改；原始狀態紀錄仍須由還原流程處理。

## 還原、停用與卸載

**只在管理器停用模組並重新開機，不會自動還原已寫入 PackageManager 的停用狀態。**暫時允許 OTA 請先執行 `restore`，確認還原結果，再視需要停用模組。

正式卸載時，模組會保留還原所需的 runtime 與紀錄，並透過本模組專屬的 `/data/adb/service.d/fuckotaupdate-restore.sh` 一次性腳本，在 Android 服務可用後執行還原。該腳本只在有待完成的卸載還原時存在；成功驗證後移除，失敗或暫時不可用時保留重試與診斷資訊。不要在完成還原之前手動刪除 `/data/adb/fuckotaupdate`。

原始狀態紀錄只從 v1.2 第一次接手目標時開始。從 v1.1 升級時，無法推回 v1.1 修改前的狀態；已被 v1.1 停用的元件可能成為 v1.2 的初始基準。舊版以 `.update.*` 掃描停用、但未納入 v1.2 已啟用 allowlist 的元件，不會自動接管或恢復。v1.1 曾移除的 Factory OTA 也不會被 v1.2 自動重新安裝。若要恢復更早的設定，必須另行確認原狀，不能將這次的精確還原誤認為歷史修復。

## 紀錄與卸載後診斷

在裝置 root shell 查看：

```sh
tail -n 100 /data/adb/fuckotaupdate/ota.log
cat /data/adb/fuckotaupdate/mode
cat /data/adb/fuckotaupdate/runtime.path
```

`ota.log` 在超過 100 KiB 時保留最近約 300 行。`mode` 記錄是否啟用或處於還原流程；`runtime.path` 指向保留的完整 runtime 世代目錄。`journal.json` 保存嘗試修改前的原始狀態，已驗證還原的項目會移出待還原紀錄。`restore.pending` 表示有待完成的卸載還原。這些資料只允許 root 存取。`*.flock` 檔案存在不代表鎖仍被占用，不需手動刪除。

如果模組目錄已被移除，但需要手動診斷或重試還原，可使用持久 runtime：

```sh
RUNTIME=$(cat /data/adb/fuckotaupdate/runtime.path)
sh "$RUNTIME/cli.sh" diagnose
sh "$RUNTIME/cli.sh" restore
```

不要編輯原始狀態紀錄或 `runtime.path` 來消除錯誤；先保留診斷資料，確認還原失敗的原因。

## 未來 OEM 適配

profiles 將目標資料與套用／還原機制分離。新增 OEM 時，先確認實際負責 OTA 的套件和元件，再建立明確 allowlist；不要只依品牌、套件名稱包含 `update`，或整個命名空間就停用。

格式如下，這是未啟用的示意資料，**不是任何真實裝置的適配規則**：

```text
# profiles/example-oem.profile（示意，不隨模組啟用）
component|com.example.ota|com.example.ota.VerifiedOtaService|core
component|com.example.ota|com.example.ota.VerifiedOtaActivity|optional
# package 規則會停用整包，只有確認整包專用於 OTA 時才可考慮：
package|com.example.dedicatedota|-|optional
```

每行為 `類型|套件|完整元件類別名或 -|core/optional`。`core` 是已知更新路徑的識別依據，只有 `component` 規則可以標記；`package` 規則只能是 `optional`。`optional` 表示缺少該項仍可相容，不代表該項存在時可忽略驗證。不得使用萬用字元。profile 名稱須以小寫字母開頭，使用小寫字母、數字、`_` 或 `-`，最多 32 個字元。新 OEM profile 必須預設停用，經人工審查後才加入 `ENABLED_PROFILES`。

適配需記錄 ROM／版本、元件用途證據、更新 Intent 路徑與核心判定，並驗證套件更新、停用／還原、多使用者及重開機；同時確認正常開機、設定精靈與一般 Play 功能未受影響。OEM 若透過其他系統 daemon 或更新引擎路徑執行更新，新增套件清單可能不足，應先分析而非自動擴大阻擋。

## 驗證紀錄

### 2026-10-11：Nothing A142

2026-10-11 的實機環境：Nothing A142／Pacman、Android 16／API 36、Google Play 服務 `26.36.35`（`263635035`）、SukiSU-Ultra `ksud 4.2.0-1-g904c60d1`。測試使用既有使用者 0、10，沒有建立額外使用者。

| 情境 | 結果與範圍 |
| --- | --- |
| 首次套用 | 兩位使用者共找到 24 個目標；19 項修改、5 項原已停用，另 16 個不存在的相容目標正常略過。 |
| 重複套用 | 0 項修改、24 項已停用；沒有反覆重寫元件狀態。 |
| 精確還原 | 還原 19 項，全部 24 項與測試前基準相符，涵蓋 default 0、明確啟用 1 及原已停用 2。 |
| Watchdog 修復 | 人工重新啟用一個 OTA Activity、未啟動它；觀察到 14 秒內自動修復，原始狀態紀錄 SHA-256 不變。這不是保證延遲。 |
| 暫停與錯誤設定 | 已暫停的 Action 回傳 4，沒有恢復套用；設定檔錯誤時仍可完成還原。 |
| 不支援／紀錄損壞 | 隔離測試中，無核心能力回傳 3 且未建立紀錄；損壞紀錄回傳 4 且未修改元件。 |
| 生命週期回歸 | 裝置 Shell 中 40 個 assertions、0 個失敗；涵蓋模式、設定解析、查詢失敗及操作控制。 |
| 模組目錄消失後還原 | 持有操作鎖時執行卸載 hook，確認它直接返回，再移走測試模組目錄；解鎖後持久 worker 還原全部 24 項，待還原紀錄清空，pending 標記與專屬開機腳本均移除。 |
| SukiSU ZIP 安裝 | 管理器安裝回傳 0，寫入 `/data/adb/modules_update/FuckOTAUpdate`；清單顯示 v1.2／12、已啟用且待重開機更新，原本已還原的模式與空紀錄均保留。 |
| 待安裝副本的停用標記 | 隔離測試確認，待安裝副本也會尊重已安裝模組的 `disable`／`remove` 標記。 |
| 真實 GMS 更新／重開機 | 本輪未測試；未自動重新開機。 |

卸載測試模擬 staged 模組目錄消失，並非實際管理器在開機階段執行卸載；本輪 boot ID 未變，系統 `update_engine` 仍存在並執行。ZIP 安裝成功也不等於已驗證重開機後載入。人工重設元件不等同真實 Play 服務更新，ADB 即時套用也不等同重新開機驗收。上述 A142 結果不代表已驗證其他 ROM、Magisk、舊 Android 版本、初始設定流程或所有一般 Play 功能。

### 2026-11-06：Nothing Phone (4a)，A069／Frogger

Android 16／API 36，build `BQ2A.250913.001-BP2A.250605.031.A3/2609110959`；Google Play 服務 `26.43.30`（`264330035`）；Magisk Kitsune `v27.2-kitsune-4`（`27002`）。裝置已有完整安裝的 v1.2，核心腳本與 DEX 雜湊符合本機候選包；檢查前守護程序已在本次開機中啟動，不在待安裝目錄中。

| 情境 | 結果與範圍 |
| --- | --- |
| 現有防護／重複套用 | 使用者 0 有 12 個現存目標，全部停用；8 個不存在的相容目標略過，修改 0、失敗 0，原始狀態紀錄雜湊不變。 |
| 裝置生命週期測試 | Android Shell 與 Magisk BusyBox 下 40 個 assertions、0 個失敗，含三個鎖的跨程序競爭。 |
| 隔離原狀還原 | 只對未啟動的 `UpdateFromSdCardActivity` 使用隔離 profile／journal，驗證原狀 1 → 停用 2 → 還原 1，最後回復本機防護基準 2。實際模組 journal 未變，未啟用核心 OTA 服務。 |
| 不支援／紀錄損壞 | 隔離測試分別回傳 3（未建立 journal）及 4；沒有誤報成功。 |
| 背景自動修復 | 人工啟用同一 Activity、未啟動它；不呼叫手動 apply，約 20 秒後觀察到自動修復，journal 雜湊不變。此數值不是延遲保證。 |
| 最終狀態 | `MODE=active`、`RESULT=blocked`、12 項停用、單一守護程序；更新引擎前後均回報 `UPDATE_STATUS_IDLE`，二進位雜湊與 boot ID 未變。 |

本次未重新開機、未實際更新 GMS、未執行完整模組卸載，也未將所有 OTA 元件一次還原啟用。當前開機的自動啟動已有觀察證據，但不等於受控重開機／重複開機驗收；其他 Pixel、ROM、root 管理器版本及 ART/Mainline 阻擋仍不因此獲得驗證。

主機端生命週期測試可在提供 POSIX Shell 工具的環境中執行：

```sh
sh tests/lifecycle-test.sh
```

此測試使用臨時目錄與模擬 Android 命令，檢查設定解析、模式保留、使用者列舉與紀錄，不會修改連接的裝置。

## 線上更新與發布

更新資訊：

```text
https://raw.githubusercontent.com/lokey0905/FuckOTAUpdate/main/update.json
```

固定 ZIP 網址：

```text
https://github.com/lokey0905/FuckOTAUpdate/releases/latest/download/FuckOTAUpdate.zip
```

模組管理器需能匿名讀取更新 JSON、更新紀錄與 ZIP；Private repository 不能直接提供這條匿名更新路徑。

發布時同步提高 `module.prop`／`update.json` 版號、更新 CHANGELOG，建置 helper 並打包，確認 ZIP 根目錄為模組檔案且 Shell 腳本使用 LF。先只推送對應 tag，建立 draft Release、上傳同名 `FuckOTAUpdate.zip`，公開 Release 並驗證匿名下載後，再推送 main 的新版更新資訊；不要讓新版 JSON 指向仍是舊版的 latest ZIP。

發布預設使用 GitHub REST API：在 PowerShell 中以 `git credential fill` 從 Git credential helper 取得 GitHub 憑證至記憶體，使用 `Invoke-RestMethod` 建立 Release，再依回傳的 upload URL 上傳 ZIP。先查詢 tag 是否已存在；同名 asset 不應不經確認就刪除重傳。不得輸出 token、啟用可能記錄它的 debug／transcript，或將 token 寫入 repository、檔案或命令列參數。這套流程不需要瀏覽器登入 session。

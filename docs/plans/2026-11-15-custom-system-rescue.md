# 最高優先：自製系統 ADB 救援與自動返回 USB loader

日期：2026-11-15。優先級：P0（最高）。狀態：IN PROGRESS（2026-11-16 修訂）。

## 現況（2026-11-16）

本計畫原稿撰寫時未納入 [獨立救援證據](../mibox-independent-rescue.md)；以下依該證據修正。

| 項目 | 狀態 | 證據 |
| --- | --- | --- |
| preboot USB 視窗（env `preboot` 加 `update 10000;`） | 已安裝，完整讀回 hash `6142e34f…` | `mibox-independent-rescue.md` |
| 自製系統正常重啟 → C003 → 固定 RAM 映像 → 新自製系統 | **PASS** | `artifacts/rescue-boot/20261115-175944-393/` |
| 接主機冷開機 → C003 → 自製 console/SSH，全程不經 Android | **PASS**（兩次冷開機） | `artifacts/console-ssh/launcher-20261115-212455` |
| 未接主機冷開機：視窗到期後繼續既有開機路徑 | **PASS**（2026-11-16，一次） | 擁有者觀察：拔除 PC USB、斷電冷開機後回到 Android。無主機端記錄；`10000` 的實際時長仍未量測 |
| fail-safe PID1 一般開機（`FailSafe` 映像 `f5e9cd6b…`，init `a24de13a…`） | **PASS** | `artifacts/ram-boot/20261116-193139-812/`（Android → C003 → 完整讀回 → health） |
| PID1 panic → 自動回 C003 | **PASS**，12.4 秒，無 ADB | `artifacts/fail-safe/20261116-200046-745-panic/` |
| USB 設定失敗 → 自動回 C003 | **PASS**，12.4 秒，無 ADB | `artifacts/fail-safe/20261116-202305-984-usb/` |
| USB 設定卡住 → 60 秒 deadline → 自動回 C003 | **PASS**，72.4 秒，無 ADB | `artifacts/fail-safe/20261116-204511-921-hang/` |
| QEMU（normal/panic/usb/hang） | **PASS** | `artifacts/qemu-fail-safe/` |
| kernel panic 自動重啟 | **NOT_TESTED**；設定 `CONFIG_PANIC_TIMEOUT=20`，cmdline 是否覆寫未確認 | `artifacts/platform/2026-11-13/kernel-inspection.json` |

設計結論：已安裝的 preboot 視窗使每次重啟都經過 C003，因此「退回 loader」等同正常重啟。
A32 需要區分「退回 fastboot」與「正常重啟」，MiBOX 不需要。原第 1、2 步的
`usb_burner_reboot` 控制操作降為備援：僅在 env 視窗遭移除或失效時才有價值，不是主路徑。

PID1 fail-safe（`src/fail_safe.rs`）：panic、虛擬檔案系統掛載失敗、要求的 USB 功能
（ADB／ACM）設定失敗或 60 秒內未完成，皆先做最多 15 秒的 sync，再
`LINUX_REBOOT_CMD_RESTART`，失敗時改用 sysrq。未接 USB host 不算失敗：設定不等待列舉。
原本這些情況會讓 PID1 永久停住，只能人工斷電。故障測試映像以建置期
`MIBOX_FAULT=panic|usb|hang` 產生，獨立 `CARGO_TARGET_DIR`；一般建置不受影響，故障映像不得刷入。
QEMU：`python3 scripts/test-fail-safe-qemu.py`（WSL）。

無主機時的行為：視窗到期後開進 boot 分區現有系統（目前為 Android，冷開機已觀察一次），不會形成重啟迴圈。
自製系統未來寫入 boot 分區後，故障映像在無主機時會反覆重啟；屆時須重新評估。

### 修訂後的剩餘順序

1. ~~實機：未接主機冷開機，確認視窗到期並繼續開機~~ PASS。視窗時長仍待量測（非阻擋項）。
2. ~~以新 init 建 RAM 候選映像並實機驗證一般開機~~ PASS。`scripts/derive-fail-safe-candidates.py`
   只替換已驗證 Console rootfs 的 `init`，嚴格比對其餘 entry；映像餘量 32768 bytes。
3. ~~實機：三種故障映像各自重啟回 C003~~ PASS（`scripts/Test-MiboxFailSafe.ps1`）。
   從 C003 載回正常映像：`scripts/rescue-boot.ps1 -Action WaitAndBoot -Candidate FailSafe`。
4. 實機：kernel panic 是否在約 20 秒內重啟（PID1 已不再因自身故障觸發 kernel panic，此項降為補充）。
5. 備援：`usb_burner_reboot` 受控操作（見下方原第 1、2 步）。

P0 之後的下一項（2026-11-16 擁有者同意）：修復 C003 bulk 傳輸。目前每個 8 MiB 映像
走 EP0 control transfer，每次 64 bytes，寫入加讀回約 26 萬次往返，實測約 22 分鐘。
bulk 每次 4096 bytes，理論上可降到 1 分鐘內。兩次實測失敗後 loader 停止回應，
需要人工斷電，所以每次嘗試仍須遵守本計畫的預檢與停止條件。
參考 `docs/mibox-usb-loader-protocol.md`：先在 EP0 送出 16-byte 命令，再進入 bulk 資料階段。

**2026-11-16 已完成（PASS）：** 先前失敗是主機端 bug：WinUSB PipeID 應填端點位址，
當時誤填 pipe 索引，導致 native 87。改用 bulk OUT，以裝置端 `crc32` 加 129 點 EP0 抽樣讀回驗證，
完整 8 MiB 上傳只需 8.2 秒，載入並開機合計 23 秒。實測指令：
`scripts/rescue-boot.ps1 -Action WaitAndBoot -Candidate FailSafe -Bulk`
（`artifacts/rescue-boot/20261116-214805-314/`）。bulk IN 仍不使用。

### 紅線補充

已安裝的 preboot 視窗是目前唯一允許的 env 狀態。只能用
`target/rescue-window/rescue-env --remove` 或 `--recover-original` 變更，其他 env 寫入一律禁止。

## 原計畫（2026-11-15）

依使用者指示，本計畫優先於新增硬體功能、容器功能、長時間穩定性測試及預設開機安裝。
目標是讓自製系統獨立運作與修復；Android 不作為最終運作或救援的必要依賴。
既有 Android 返回測試保留為歷史證據，不作為本計畫的成功條件。

## 參考與現況

參考 `F:\coding\otherPrj\amazing-a32-os`：

- `scripts/ram-boot.ps1`：由自製系統主控台送出 `reboot bootloader`，再由 fastboot 載入 RAM 映像。
- `src/pid1.rs`：啟動早期 panic、主控台設定失敗或設定逾時時，自動退回 fastboot。
- `src/watchdog.rs`：運行中失去進度或較晚 panic 時正常重啟。
- `README.md` 的 Flash、Fail-safe、Watchdog 段落記錄既有實測與限制；A32 同樣沒有已證實的關機按鍵 fastboot 入口。

MiBOX 已具備自製系統 ADB、root PID1 控制通道與正常重啟，亦有 C003 RAM 載入與完整讀回流程。
目前缺少的是自製系統至 C003 的實機閉環與啟動失敗自動退回機制。
不能直接沿用 A32 的 fastboot 指令、MediaTek reboot mode 或分區配置。

## 執行順序與驗收

1. **確認 MiBOX 精確 loader 重啟語義。**
   核對現有 reboot-mode、核心 restart handler、bootloader 分支與 PID1 實作，
   確定 `usb_burner_reboot` 所需路徑；區分靜態證據與實機結果，不猜測模式值。
2. **新增自製系統至 loader 的受限控制操作。**
   經 ADB 向 root PID1 請求，沿用身分、boot ID、請求長度與逾時防護。
   持久化服務須先停止、同步與乾淨卸載；處理同步阻塞及失敗回報，避免直接繞過既有掛載保護。
   主機驗證錯誤／過期請求被拒絕，且既有正常重啟功能不受影響。
3. **實測不經 Android 的手動救援閉環。**
   自製系統 ADB → PID1 → C003 → 已固定雜湊的自製 RAM 映像 → 新自製系統 ADB。
   必須觀察正確 USB 身分、完成全映像 RAM 讀回與 SHA256 比對，再核對 OS、PID1、執行檔雜湊及新 boot ID。
   ADB 斷線、重啟接受回覆或 USB 消失不算成功；過程不以 Android 啟動作中介。
4. **加入 A32 式啟動失敗保護。**
   為早期 panic、ADB／控制介面建立失敗及建立逾時設定退回 loader 的策略。
   就緒判定以本機服務建立成功為準，未接 USB host 不得誤判為失敗。
   啟動期與穩定運行期分開處理；期限須依 MiBOX 實測決定，不直接照搬 A32 數值。
5. **以 RAM 故障候選映像驗證自動救援。**
   分別測試早期 panic、介面設定失敗與設定卡住；先通過主機／適用的 QEMU 檢查，
   再以獨立固定的 RAM 候選映像實測。不得將故障映像刷入持久分區。
   各案例都須自動進 C003，並由主機重新載入正常自製映像、驗證恢復控制。
6. **完成操作文件與狀態判定。**
   提供單一可重現的主機救援流程、明確 timeout、各階段證據與失敗處置。
   手動閉環與三種自動退回案例分別標示 PASS／FAIL／NOT_TESTED；全部通過才宣告此範圍 READY。

## 防變磚紀律（補充，2026-11-15）

本計畫全程 RAM-only，設計上「迭代失敗」的代價是斷電重來而非死棋。
以下紀律為計畫內驗收條件，違反任一條即停止該次實機測試。

### 變磚紅線（明確禁止清單）

- 任何階段禁止發出 env 寫入、`saveenv`、`fw_setenv`、分區寫入或擦除命令。
- 對 loader 協議中未驗證的主機請求不得隨意應答；已知 BT 應答路徑的後端是
  saveenv（見[還原狀態](../mibox-restoration-readiness.md)），此路徑一律不碰。
- 禁止準備或使用 `update`／`sdc_burn` 刷機包路徑；C003 會話僅限既有固定驗證的 RAM 載入流程。

### 每次實機測試前的恢復預檢

- 確認人工斷電恢復可用（遙控／插座可及）。
- 複用 `scripts/Verify-MiboxBackups.ps1` 確認 bootloader 與分區備份 SHA256 仍通過。
- 預檢結果記入當次證據目錄，與測試結果一同保存。

### 傳輸逾時與 C003 會話失敗處置

- 首次實測曾出現 1200 秒傳輸期限不足（實機記錄曾調整為 3600 秒）。
- RAM 映像傳輸逾時後**不重試、不發 loader reset**；統一走人工斷電恢復。
  此為救援流程的正式規則，適用於本計畫所有實機步驟，非僅歷史測試記錄。

### 新增 PID1 restart 操作的回退設計

- 新操作碼保持預設拒絕、顯式開啟或可停用的結構；先以 QEMU 驗證拒絕路徑
  （複用既有 platform-guard 模式），再上實機。
- 避免重蹈舊 RAM boot 中 PID1 無法升級的教訓：救援能力本身損壞即等同沒有救援。

### 分級處置與停止訊號

- 迭代失敗的預期代價是斷電重來並重跑腳本；此為正常流程，不算測試失敗。
- 出現以下徵兆立即停止實機測試，改回 QEMU／靜態分析：
  loader 出現非預期提示、重啟模式值行為與靜態審計不符、
  C003 會話行為偏離既有記錄、或需要發出任何未驗證命令才能繼續。

## 救援範圍與後續安裝

本計畫首先建立可執行核心與 PID1 的自製系統救援能力，不要求先找到冷啟動按鍵入口。
核心／PID1 完全無法執行、bootloader 損壞與儲存硬體故障不在上述軟體退回機制的保證內；
獨立冷啟動救援維持另一項未解限制。

進入持久安裝前，另須核對實際目標分區、備份、寫入與完整讀回方案，並完成相應還原驗證。
RAM 重新載入成功不等同已具備分區刷回能力。
本次工作是排定計畫，不執行重啟、刷寫、bootloader／env 修改或刪除 Android。

相關證據：[loader 分支](../mibox-loader-entry-branches.md)、
[PID1 正常重啟](../mibox-software-return.md)、
[既有 RAM 載入流程](../mibox-automated-ram-boot.md)、
[持久化服務](../mibox-console-ssh.md)、[還原狀態](../mibox-restoration-readiness.md)。

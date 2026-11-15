# MiBOX1S 儲存、影音、休眠、溫度穩定性與 USB 實機測試計畫

日期：2026-11-15。狀態：PARTIAL，依使用者「這樣就好了」結束本輪實測；完整五項驗證尚未完成。

目標是在自製 userspace、實際 MiBOX1S 上建立可重現的硬體驗證結果。
本計畫涵蓋指定的五項，不等同整機所有硬體認證。
目前沿用原廠 Linux 3.10.33 與 DTB；結果不可延伸到尚未實測的新核心。

## 基線與已知限制

- 有線 Ethernet 使用 192.168.1.222/24，閘道 192.168.1.1；保留作為主要控制連線。
- HDMI 色條、低振幅立體聲聽測已通過；這不代表影片播放或硬體解碼已通過。
- 隱藏 Wi-Fi 已使用 .223 通過連線與閘道／外部 IP 測試；關閉再啟用會發生驅動逾時。
  壓力與喚醒測試不得把重新載入驅動後恢復寫成自動恢復通過。
- SSH shell 位於持久化 Alpine chroot，`/tmp` 也可能在磁碟上。
  RAM 暫存須以 PID1 的 root 與實際 mount table 驗證，例如從 SSH 存取 `/proc/1/root/tmp`。
- 持久化 userspace 與 Android 共用 data 空間，先前剩餘空間約數百 MiB；執行前重新量測。
- 原有 restart 控制拒絕 block filesystem 掛載。返回 Android 前須先停止持久化服務，
  同步並乾淨卸載，依既有 Console 返回流程操作，不以一般 reboot 指令取代。

參考：[Console 與持久化流程](../mibox-console-ssh.md)、
[Wi-Fi 實測紀錄](2026-11-15-wifi-test.md)、
[系統分割區備份](../mibox-system-backups.md)。

## 執行順序與共通規則

1. 建立實機基線與溫度監控，確認控制及復原路徑。
2. 執行內建儲存讀寫。
3. 執行 USB 枚舉、輸入裝置與儲存測試。
4. 執行軟體影音播放，再驗證可用的硬體解碼路徑。
5. 以分級負載驗證溫度與穩定性，短測通過才進入長測。
6. 確認可喚醒來源及回復措施後，執行休眠／喚醒。
7. 喚醒後重跑儲存、USB、影音及網路短測，最後驗證乾淨返回 Android。

- 每階段先做 1 次短測；通過才增加循環或時間。實際人工插拔與聽／看觀察需使用者配合。
- 每個動作有 timeout、退出碼與清理步驟。主機記錄器不得依賴裝置上的負載程序。
- 不格式化、不改分割區、不寫裸 block device、不改 bootloader，也不做突然斷電寫入測試。
- 儲存測試只在新建且明確指定的測試目錄內操作；不覆寫 Android、套件或其他使用者檔案。
- 使用已核對雜湊的檔案與工具；若需更換 RAM candidate，保留舊 pins，完整讀回比對後才開機。
- 狀態採 PASS、FAIL、BLOCKED、UNKNOWN、NOT_TESTED，分別註明實測範圍。
  缺感測器、周邊或解碼證據時，不用推測補值。

## 0. 基線與監控

- [ ] 保存 boot ID、kernel、DTB／candidate 與工具雜湊、mount table、分割區識別、空間、
  CPU／RAM 資訊、網路路由、USB 拓樸及測試前 kernel log。
- [ ] 核對目前持久化資料與備份；記錄測試目錄的 resolved path、掛載來源及可用空間。
- [ ] 盤點 thermal zones、hwmon、CPU frequency、trip points、溫度單位與對應硬體。
  無法證實的感測器意義或單位標 UNKNOWN。
- [ ] 建立每 5 秒取樣的監控：溫度、頻率、CPU 負載、記憶體、I/O、程序存活與 host 心跳。
  舊核心若沒有 MemAvailable，保留 UNKNOWN，另存 MemFree、Buffers、Cached，不假稱等價。
- [ ] 確認 Ethernet SSH、USB ADB 及現有返回流程可用；主機保存復原操作與裝置識別。

通過標準：證據收集及清理流程可用，測試寫入目標明確，能區分 RAM 與磁碟。
若無可信溫度資料或安全停止條件，仍可做有界功能短測，但長時間負載測試 BLOCKED。

## 1. 內建儲存讀寫

- [ ] 在已辨識的 data filesystem 建立專用目錄，記錄基線可用空間與既有檔案 sentinel 雜湊。
- [ ] 測試集總量取 `min(64 MiB, 當前可用空間的 10%)`，保留至少 256 MiB 空間；
  若無法保留，縮小測試或標 BLOCKED，不清除其他檔案騰空間。
- [ ] 先測 4 KiB、1 MiB、16 MiB 檔案；以可重現但非全零內容寫入，保存預期 SHA256。
- [ ] 驗證完整寫入、fsync、close、重新 open 後逐位元組／SHA256 比對。
  執行 10 輪建立、改名、讀回與刪除；另測合法短寫處理及可控的子程序中止後清理。
- [ ] 分開記錄資料同步與目錄同步；不要只用 shell 指令 exit 0 當耐久性證明。
- [ ] 分開報告快取讀取與實體 I/O 證據；若做 O_DIRECT，先確認檔案系統與對齊支援。
  不用全域 drop_caches 干擾正在執行的系統；無法排除快取時明確標記。
- [ ] 乾淨卸載、正常重啟後，讀回保留的測試 sentinel 與 SHA256，再精確清理測試目錄。

通過標準：所有內容比對一致、同步成功，無新 I/O／ext4 錯誤；重啟後 sentinel 保留，
既有 sentinel 不變，測試檔清理完成。速度為觀測值，不先設沒有基準的效能門檻。
正常重啟保存不代表突然斷電安全，也不代表完整 eMMC 壽命驗證。

## 2. USB 周邊

- [ ] 盤點 host／device 控制器、實體接口、速度與供電資訊；區別 ADB gadget 與 USB host 功能。
- [ ] 使用者準備鍵盤、滑鼠及一支允許建立測試檔的隨身碟；需要時準備有供電 Hub。
  未提供的裝置類別記 NOT_TESTED，不把單一隨身碟通過延伸成全部 USB 通過。
- [ ] 鍵盤驗證按下／放開事件與指定按鍵；滑鼠驗證移動、左右鍵與滾輪。
  必須在自製系統觀察事件，不能只記錄枚舉成功。
- [ ] 隨身碟以插入前後裝置清單、VID/PID／序號／容量確認身分，先唯讀掛載與雜湊讀取。
- [ ] 需要寫測時，只在使用者指定且允許寫入的隨身碟專用目錄執行第 1 節的小型測試，
  sync、卸載後才拔除；不格式化、不測拔除中的寫入。
- [ ] 每類周邊執行 10 次安全插拔，檢查枚舉、功能、卸載、資源與錯誤紀錄；各 host 插孔分別記錄。
- [ ] 若測 Hub，先單一周邊，再鍵鼠與隨身碟並用；記錄速率與供電限制，不假設所有插孔獨立。

通過標準：每次枚舉與實際功能成功，無資料損毀、不可恢復斷線或 kernel 錯誤；
SSH／ADB 控制仍可用。需要更換線路時由使用者操作，不自動切換 USB 角色而失去控制。

## 3. 影音解碼與輸出

- [ ] 盤點實際 decoder device nodes、驅動、ioctl、userspace library 與 framebuffer／音訊輸出路徑。
  沿用可追溯的原廠驅動／library 前，先核對 ABI 與授權／來源資訊。
- [ ] 準備可重現測試片：色彩／動態圖樣、幀編號、固定音與同步閃光；記錄 SHA256、
  codec、profile、level、解析度、fps、bitrate、時長與音訊格式。
- [ ] 起始矩陣：H.264 720p30、H.264 1080p30 搭 AAC stereo；MPEG-2／其他格式依盤點結果加入。
  每片先 30 秒，再 5 分鐘、3 輪；未確認能力的 codec 不預設支援。
- [ ] 先建立軟體解碼對照：解碼輸出幀數與參考雜湊，再驗證實際 HDMI 畫面及聲音。
- [ ] 硬體路徑需同時有 decoder 選擇／裝置活動或可追蹤呼叫的證據、解碼進度與實際輸出。
  僅 CPU 降低、播放器宣稱加速、ALSA 收到 PCM 或可開檔，都不足以判定硬體解碼通過。
- [ ] 記錄解碼錯誤、輸出幀率、掉幀、音訊 underrun、CPU／溫度及 A/V 同步。
  若能量測同步，目標偏差不超過 100 ms 且無累積漂移；只有人工觀察時記為主觀結果。
- [ ] 測試開始、正常結束、重播、停止及 3 個 seek 位置；確認 decoder／音訊資源釋放。

通過標準：各格式分項有完整解碼與輸出證據，無解碼錯誤及可見／可聞異常；
即時播放目標為完成暖機後掉幀率不超過 1%，同時列出實測值。
軟體、硬體、顯示、聲音、同步分項判定。缺 vendor ABI 或可用播放器時列具體 blocker。

## 4. 溫度與長時間穩定性

- [ ] 記錄室溫、外殼／擺放／通風、電源與接線，避免改變散熱條件造成不可比較結果。
- [ ] Idle 15 分鐘，接著 CPU、RAM、唯讀 I/O、影音負載各 10 分鐘，再混合負載 30 分鐘。
  RAM 工作集不超過實體 RAM 的 25%，且保留量需依基線確認；不刻意觸發 OOM。
- [ ] 寫入量另外設總量上限，長測以循環讀與影音為主，不持續覆寫 eMMC。
- [ ] 短測通過後執行 2 小時混合負載，再進入 8 小時資格測試；24 小時可作後續加強項。
- [ ] 安全溫度門檻依已核實的 sensor/trip 與板級資料設定，保留至少 5°C 停止裕量。
  不直接套用其他 SoC 門檻；若無可信上限，長時間負載 BLOCKED。
- [ ] 達停止門檻、熱保護事件、資料雜湊錯誤、OOM、I/O error 或非預期重啟時立即停止負載，
  保存最後紀錄並維持 idle 散熱。USB 與 SSH 都失聯則停止進一步命令，依預定復原方式處理。
- [ ] host 心跳每 5 秒一次；連續 3 次缺失記異常並查 USB／程序狀態，不先當作設備死亡。
  每階段比較 boot ID、程序退出、kernel 新錯誤及 warm-up 後記憶體趨勢。

通過標準：指定時長完成、未達停止門檻、無非預期重啟／OOM／資料錯誤／持續資源洩漏，
負載停止後功能可重測。正常 thermal throttling 記錄頻率與效能影響；持續降頻影響播放則功能失敗。
8 小時通過只代表該負載、環境及版本，並非無限期可靠性承諾。

## 5. 休眠與喚醒

- [ ] 盤點 `/sys/power/state`、wakeup devices、RTC alarm 與 PM kernel log；分清螢幕熄滅和系統 suspend。
- [ ] 確認可用喚醒來源及使用者可操作的電源／遙控器，先驗證 RTC 若可用。
  沒有可信喚醒來源或現場復原條件時，進入 suspend 的測試 BLOCKED。
- [ ] 記錄 data 同步狀態、USB 周邊掛載、網路及影音資源；先停止寫入並安全卸載外接儲存。
- [ ] 先測 1 次 10 秒短休眠，再 60 秒、5 分鐘，最後執行 20 次循環。
  可用時設定 RTC 作備援，逐一測遙控器、實體按鍵、USB 鍵盤等實際支援的來源。
- [ ] 主機從外部記錄斷線及回復時間，裝置記錄 PM 進入／恢復與 wakeup reason。
  以 kernel PM 證據及可用時電流量測確認，不能只憑 ping 中斷宣稱進入低功耗。
- [ ] 每次恢復後 30 秒內檢查 SSH／ADB、boot ID、Ethernet、HDMI、音訊、USB、儲存雜湊；
  Wi-Fi 的連線恢復與驅動重載需求另外記錄。

通過標準：20 次均完成真正 suspend／resume，boot ID 不變、無人工重啟，
各喚醒來源分項成功且後續功能完整。需重載 Wi-Fi 才恢復時，Wi-Fi resume 子項 FAIL，
不得用整體 suspend 成功掩蓋。休眠期間的網路不可達本身不算失敗。

## 證據與完成條件

每次執行存於 `artifacts/hardware-validation/<timestamp>/<stage>/`：

- `baseline.json`：硬體、boot ID、candidate／工具 pins、環境與前置狀態。
- `commands.json`：動作、開始／結束、timeout、退出碼及完整輸出狀態；不含密碼或私鑰。
- `metrics.csv`、kernel log 前後差異、資料／片源 SHA256、使用者影音／插拔觀察。
- `result.json`：每個子項的期望、實際、PASS／FAIL／BLOCKED／UNKNOWN／NOT_TESTED、
  blocker、cleanup 與已知限制；失敗紀錄保留，重測另建 run。

完成條件：五項矩陣均有結果及證據；FAIL／BLOCKED 先修復並重測才算該項完成。
最後核對測試目錄、程序、掛載、路由及敏感暫存檔清理，驗證有線控制與乾淨 Android 返回。
## 本次執行紀錄

- 開始時實機為原廠 Android，boot completed=1，boot ID
  `780c872e-b8a2-48dc-bbcb-3b23582a85db`。已啟動既有 Console 完整 RAM 上傳／讀回流程：
  `artifacts/ram-boot/20261115-164756-709/`。開機結果須等流程完成才判定。
- 使用者目前沒有可測 USB 周邊：鍵盤、滑鼠、隨身碟功能與插拔均為 NOT_TESTED。
  使用者在現場，可協助喚醒與必要時重新接電復原；仍須先核對喚醒路徑。
- 新增 `scripts/validate-hardware-device.py`，經 USB 核對 SSH 主機金鑰及 boot ID 後收集基線。
  可指定 `--storage-helper target/storage-check/storage-check` 執行專用目錄短測。
- 儲存工具建置：在 WSL 執行 `python3 scripts/build-storage-check.py`。
  工具強制 ext filesystem、保留 256 MiB、單檔不超過可用空間 10%，
  10 輪各測 4 KiB、1 MiB、16 MiB，包含檔案 fsync、close、rename、目錄 fsync、
  reopen 逐位元組比對及刪除。SSH harness 另核對 data 裝置 179:11、5168640 sectors、
  專用測試目錄所在裝置與 RAM 暫存 filesystem，並比較既有 sentinel 雜湊。
- QEMU ARM 主機短測通過，證據：`artifacts/hardware-validation/host-storage-check/`。
  此為工具驗證，不是 MiBOX 儲存通過。快取未排除、重啟保留、強制短寫與中止恢復尚未測。
- 原廠 config 啟用 `AML_VIRTUAL_THERMAL`，停用 `AMLOGIC_THERMAL`。
  參考 BSP 的溫度函式存在虛擬估算／固定 45 度路徑；它不是精確原廠來源，
  不足以判定實機讀值。證據：`artifacts/hardware-validation/reference-thermal/assessment.json`。
  實機 sensor、單位及可靠安全上限仍為 UNKNOWN，長時間負載尚未啟動。
- 已在核對完整雜湊的 system1 備份唯讀盤點媒體庫，並離線分析 `libamplayer.so`、
  `libamffmpeg.so`、`libOmxCore.so` 的 ELF 依賴。它們含 Android media／Binder 等依賴，
  不能當成已在 Alpine 整合的播放器。證據：`artifacts/hardware-validation/offline-media-inventory/`。
- 主機 WSL 已安裝 FFmpeg，執行 `python3 scripts/prepare-hardware-media.py` 產生
  H.264 Constrained Baseline 720p30／1080p30、48 kHz stereo AAC 的 30 秒測試片，
  每片 900 幀的主機參考雜湊及 codec／bitrate 資訊存於
  `artifacts/hardware-validation/media-fixtures/`；片源位於 `target/hardware-media/`。
  幀編號及每秒同步閃光／低振幅提示音為後續觀看、聽測基準，尚不是實機影音結果。
- ARM 工具準備：在 WSL root 執行 `python3 scripts/prepare-media-tools.py --destination <新的 Linux 目錄>`。
  以既有固定 SHA256 的 Alpine 基底及預設受信任套件簽章安裝 FFmpeg；工具壓縮檔約 36.9 MB，
  解壓後檔案約 71.4 MB。證據：`artifacts/hardware-validation/media-tools/`。
  `scripts/validate-media-device.py --private-key <owner key>` 會先核對 USB／SSH boot ID、
  tmpfs、至少 256 MiB MemFree，再暫存工具、逐檔核對雜湊，對每支片執行最長 90 秒的
  軟體解碼與 900 幀參考比對，最後清理 RAM 暫存。此步不等於 HDMI、聲音或硬體解碼通過。

## 本輪實機結果（使用者確認後停止）

| 項目 | 結果與邊界 | 證據 |
| --- | --- | --- |
| Console RAM 開機 | PASS：8 MiB 完整上傳／讀回及 pinned SHA256 一致，自製 PID1／工具與新 boot ID 核對成功 | `artifacts/ram-boot/20261115-164756-709/` |
| 基線／監控 | 已盤點；6 次約 5 秒間隔取樣。MemTotal 877072 KiB、MemAvailable UNKNOWN、data 可用 437432 KiB。未完成 15 分鐘 idle 資格測試 | `artifacts/hardware-validation/20261115-171258/baseline/` |
| 儲存有界短測 | PASS：10 輪各 4 KiB、1 MiB、16 MiB，fsync／close／rename／reopen 逐位元組比對／刪除及目錄 fsync 成功，既有 sentinel 不變，專用目錄與工具清理完成 | 同上 `baseline.json`、`storage-short.txt`、`storage-cleanup.txt` |
| 儲存完整資格 | NOT_TESTED：快取未排除、未測重啟後新 sentinel 保留、強制短寫或中止恢復，不宣稱完整 eMMC 驗證 | 同上 |
| 軟體解碼 | PASS：720p30、1080p30 各 900 幀與主機逐幀 SHA256 完全一致；解碼含雜湊輸出約 36.94／78.26 秒，不能當即時播放通過 | `artifacts/hardware-validation/20261115-172008/software-media/` |
| 遙控器 | PASS（已測範圍）：使用者確認操作後觀察到 code 105／106 的按下、放開；清醒輸入不等於 suspend 喚醒 | `artifacts/hardware-validation/20261115-172250/remote-input/` |
| HDMI／聲音可見可聞 | PASS（功能確認）：第一次僅 logo；重用既有相同幾何設定、目前頁面 pan、unblank 流程後，使用者確認「有畫面了」及「有提示音，畫面流暢」 | `artifacts/hardware-validation/20261115-172848/software-media/`、`artifacts/hardware-validation/owner-observations.json` |
| 720p30 即時播放 | FAIL：接管後量測約 14 fps、speed 0.481x，718 幀／23.91 秒媒體進度後達 50 秒上限；有 ALSA buffer xrun。主觀觀看正常與量測限制分別保留 | 同上 `h264-720p30-playback.txt` |
| 硬體解碼 | NOT_TESTED：尚未建立可追溯 ABI 的獨立播放器與 decoder 活動／進度／輸出證據 | `offline-media-inventory/`，僅離線庫與設定盤點 |
| USB 周邊 | NOT_TESTED：使用者未提供周邊；僅盤點 DWC host／ADB gadget，不宣稱鍵鼠或隨身碟通過 | 基線 inventory／kernel log |
| 溫度長測 | BLOCKED：未找到 thermal zone／hwmon 感測器，安全上限 UNKNOWN | 基線 inventory、`reference-thermal/assessment.json` |
| suspend／resume | NOT_TESTED／BLOCKED：有 mem 介面與 aml_rtc，但 wakealarm 讀取 Invalid argument、wakeup_count 讀取會阻塞，尚未驗證 RTC 告警與喚醒；未寫入 suspend 或 RTC 告警 | 基線 inventory；清醒遙控器成功不足以替代喚醒測試 |

目前 boot ID 為 `b5567c71-9f2e-4d73-9239-0a80e7120ab3`，保持 Console 系統。
影音程序均已結束，RAM 工具／片源暫存已清理。本輪未執行返回 Android、重新開機保留或後續硬體解碼試驗。
第一次 wakeup_count 阻塞、tmpfs-only 守門拒絕 ramfs、ramfs 的 df 無可報告 block 數、
媒體封裝缺少 pulseaudio 子目錄共享庫，以及兩次有逾時的播放結果均保留原始紀錄。
後續已明確支援實測 ramfs magic、為阻塞介面設個別逾時、補齊共享庫並完成清理。

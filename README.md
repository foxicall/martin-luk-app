# Martin Luk 台美股動能策略 App

最新版本為 **1.3.2+6**：總覽明示手機精選池與實際評估數，推薦清單下方收合來源提示，設定頁新增 Python API 連線與掃描範圍檢查。你目前尚未部署 API，請依 [FULL_MARKET_SETUP.md](FULL_MARKET_SETUP.md) 完成雲端部署，再設定 App；APK 更新本身不會建立伺服器。美股名錄解析與取消測試修正一併保留。

本版將股票池擴充為**台灣上市＋上櫃普通股**，以及 **NYSE、Nasdaq、NYSE American 的可確認普通股**。Flutter 提供動能總覽、個股風控、庫存診斷與離線搜尋；Python API 以有界背景工作逐頁掃描已取得的股票名單。全市場輪掃請在 App 設定選擇「Python API」，並填入實際部署的 HTTPS 根網址。

這份交付包含原始碼、Android 建置設定、GitHub Actions 與 Render 設定。尚未由本環境完成 Flutter／APK 建置或雲端部署，也沒有已建立的上線網址。更新步驟見 [ALL_STOCKS_UPDATE.md](ALL_STOCKS_UPDATE.md)，部署見 [CLOUD_API_GUIDE.md](CLOUD_API_GUIDE.md)，APK 見 [README_HOW_TO_BUILD.md](README_HOW_TO_BUILD.md)。

## 股票池與分類邊界

| 模式／市場 | 來源與範圍 | 需留意的分類限制 |
|---|---|---|
| Python 台股 | TWSE ISIN `strMode=2` 上市、`strMode=4` 上櫃，四位數代碼及 CFI `ES` 普通股 | 上市加 `.TW`，上櫃加 `.TWO`；排除存託憑證、特別股、ETF 等 |
| Python 美股 | NasdaqTrader `nasdaqlisted.txt`、`otherlisted.txt`，限 Nasdaq／NYSE／NYSE American | 目錄沒有完整 CFI，採保守證券名稱規則；排除 ADR／ADS、特別股、ETF、基金、權證、單位與無法確認類型，不宣稱百分之百官方普通股分類 |
| Flutter 直接連線 | 台股官方上市／上櫃發行公司 JSON；美股上述 NasdaqTrader 目錄 | 台股發行公司資料不是逐筆 CFI 認證；直接連線仍只評估最多 30 檔核心成員或指定個股 |
| 離線搜尋 | `stocks_master.json` 及內嵌於 HTML 的同一元資料 | 是隨包快照，不是即時行情或當日成分保證；來源、數量及時間以 `stocks_master_sources.json` 為準 |

「全市場」指已取得並通過目前來源分類的名單，不含其他美國交易所、OTC、台灣興櫃、ETF 或未能確認類型的證券。單一來源失敗、舊快取與保守排除會揭露警告，不能把來源取得成功當成所有證券分類已官方核證。

## 每頁 60 檔的背景輪掃

預設 `MARTIN_SCAN_POOL_LIMIT=0`，表示不再把後端選定池截斷為 30 檔；每次背景工作仍只處理 **60 檔的一頁**，每批 3 檔、批次間隔至少 150ms、提供商 HTTP 期限 8 秒。`background=true` 首次回 `202` 與進度，不等待整個股票池。每市場共用一個進行中的工作，App 約每 3 秒查詢該工作的狀態。

完成當頁後，若還有未嘗試標的，快照有效期限採 `min(MARTIN_RESPONSE_TTL=300, MARTIN_SCAN_PAGE_INTERVAL=60)` 秒。App 在前景每 60 秒一般更新時可啟動下一頁；手動強制更新可直接推進。工作尚未結束時會共用既有工作，不平行重複掃描。整輪完成後，下一輪使用 300 秒的一般快取期限。

這是**由前景更新或明確請求推進的輪掃**。App 退到背景後不會自行持續掃完整個市場；伺服器也不會只因完成一頁就無人連續啟動所有下一頁。需要固定時間評估時可明確配置 Python 排程。

| 欄位 | 意義 |
|---|---|
| `universe_count` | 本次來源取得及分類後的市場名單數 |
| `scan_page_start`／`scan_page_size` | 本頁起點（從 0 起）／本頁排定檔數 |
| `evaluated_count` | 本頁成功驗證行情與必要指標的檔數 |
| `coverage_total_count` | 這一輪選定池的總數；預設不設池上限 |
| `coverage_scanned_count` | 這一輪已嘗試的累積檔數，**包含失敗** |
| `coverage_evaluated_count` | 這一輪成功驗證的累積檔數 |
| `coverage_remaining_count` | 這一輪還沒嘗試的檔數 |
| `coverage_round` | 輪次；名單全部嘗試後才開始下一輪 |

已嘗試不等於成功取得行情。當頁的 RS 百分位及候選清單只比較**本頁**通過資料、ADR 與指標條件的股票；不合併不同時間的頁面冒充全市場同步排行榜。台灣上市與上櫃目前共用 `^TWII` 加權指數為 RS 基準，並非櫃買指數；美股使用 `^GSPC` 為比較基準，但股票池不再限 S&P 500。

## 手機、雲端與更新

1. 將完整覆蓋包解壓，在 GitHub 網頁上傳到 `fix/refresh-live-gate-20261014` 分支的專案根目錄；保留 `.github/`、`lib/`、`backend/`、`android/` 與其他資產。
2. 重新部署 Render。既有服務的 Environment 若還是 `MARTIN_SCAN_POOL_LIMIT=30`，必須改為 `0`，並設定 `MARTIN_SCAN_PAGE_SIZE=60`、`MARTIN_SCAN_PAGE_INTERVAL=60`。更新原始碼不會自動覆蓋手動保存的舊環境變數。
3. 透過 GitHub Actions 或本機 Flutter 重建 APK，安裝新版。在設定關閉 Mock，資料來源選 Python API，保存 Render 提供的 HTTPS **根網址**，不要附加 `/v1` 或 `/health`。
4. 先測 `/health`，再測 `/v1/candidates?market=tw&background=true` 與美股同一端點，最後檢查 App 的頁面與累積覆蓋數。

舊版只含上市／S&P 500 的股票池與回應快取不會用來冒充新範圍。新後端使用新版名單快取及 `responses_expanded_v2` 回應目錄；輪掃游標位於 `MARTIN_CACHE_DIR/scan_coverage/`。名單指紋變更會重建對應進度。Render 免費服務本機磁碟是暫存，重啟／部署可能讓進度重頭開始。

## 策略、風控與庫存

ADR 採 `SMA((High-Low)/Low, 20)*100`，台股預設 3.5%，美股 5.0%。掃描包含跳空／量能、1～3 日強勢股、20／60 日相對動能；確認使用均線收斂、PDH／ORH 等已完成 K 棒證據。PDH／ORH 觸發界線與確認棒價格分列，歷史確認不代表能依觸發價成交。

```text
每股 1R = 進場價 − 實際初始停損
單筆名目風險 = 帳戶淨值 × 0.005
股數 = floor(min(風險預算 / 1R, 淨值 × 曝險上限 / 進場價))
曝險上限：已確認大型流動性股 35%，其餘 25%
3R／5R／10R = 進場價 + 3／5／10 × 原始 1R
```

台股與美股本金分開保存，預設 NT$1,000,000／US$50,000，不進行匯率換算。突破當時已知的當日低點距離大於零且不超過 5% 時可用；超過 5% 時，必須取得實際 1／5 分鐘進場棒低點且距離為 1.5%～3%，否則只列觀察。單獨的嚴格風控試算 helper 可要求 1.5%～3%，不代表所有日低點訊號被改成該範圍，也不會反推虛構停損。

「我的持股」可增刪改庫存、查看固定原始 R、保本與 EMA 追蹤診斷。報價與推薦分開取得，不要求持股出現在本頁候選。規則及範例見 [PORTFOLIO_GUIDE.md](PORTFOLIO_GUIDE.md)。系統只產生建議，不送券商訂單；0.5% 是按停損價計算的名目風險，跳空、滑價與費用可能增加實際損失。

## 建置與檢查

```bash
python -m pip install -r backend/requirements-dev.txt
python -m unittest discover -s backend/tests -v
python -m unittest discover -s scripts/tests -p 'test_*.py' -v
flutter pub get
flutter test
flutter build apk --release --dart-define=USE_MOCK_DATA=false --android-skip-build-dependency-validation
```

CI 以實際行情取得與 ADR／EMA／RS 計算正確為門禁；**零推薦合法**，不為了產出候選降低門檻。門禁只驗其指定測試標的，不代表全市場當日行情全部已成功掃描。Android 配置為 minSdk 21、targetSdk 34、compileSdk 36。正式 APK 預設不使用 Mock；離線 HTML 及明確開啟的 Mock 始終標示示範資料。

檔案配置及 APK 操作見 [README_HOW_TO_BUILD.md](README_HOW_TO_BUILD.md)，GitHub 網頁覆蓋見 [GITHUB_MANUAL_UPDATE.md](GITHUB_MANUAL_UPDATE.md)，後端合約見 [backend/README.md](backend/README.md)，搜尋見 [SEARCH_GUIDE.md](SEARCH_GUIDE.md)，本次可確認狀態見 [BUILD_STATUS.md](BUILD_STATUS.md)。

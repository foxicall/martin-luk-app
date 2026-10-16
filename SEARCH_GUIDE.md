# 台美股離線搜尋：上市、上櫃與美國三大交易所

搜尋支援台灣上市 `.TW`、上櫃 `.TWO`，以及 Nasdaq／NYSE／NYSE American 名單內的可確認普通股。推薦列與持股表單使用 200ms 防抖，最多 8 筆結果；可輸入代碼、中英文名稱、別名或簡碼。搜尋是本機元資料查詢，不發出行情請求，也不產生交易訊號。

## 隨包字典的實際範圍

本次隨包 `stocks_master.json` 共 **7,091** 筆身分資料：US **5,113**、TW **1,978**（上市 **1,085**、上櫃 **893**）。這是可離線重建的廣泛搜尋快照，**不是已核證當日完整普通股清單**。筆數會隨後續刷新改變；精確來源、分類結果與時間以 [stocks_master_sources.json](stocks_master_sources.json) 及 [metadata_snapshots/SOURCES.json](metadata_snapshots/SOURCES.json) 為準。

- 美國以 2026-10-14 的兩份 NasdaqTrader 名錄快照保守分類。原名錄沒有完整 CFI；ADR／ADS、特別股、ETF、基金等被排除，150 筆無法確認類型者也排除。名稱規則可能遺漏普通股，不能把兩份來源取得成功稱為百分之百官方分類。
- 台灣搜尋身分使用較早的上市／上櫃發行公司鏡像，鏡像 commit 是 2026-10-06，來源程式可能沿用個別市場舊資料，不能以 commit 時間證明每筆最新。已排除可識別 TDR 的六碼及四碼 `91xx` 身分。
- 其中 1,941 筆符合 2026-03-26 舊 CFI `ES` 快照；37 筆未匹配該舊 CFI。這不代表 37 筆已證明非普通股，也不能宣稱已取得它們的當日 CFI 認證。
- 台灣中文簡名使用 2026-10-14 衍生身分資料補強；只帶入身分／名稱，不把其中價格、估值或指標當作本 App 行情。

離線字典包含上述不同日期資料，沒有單一共同的當日 as-of。啟動 App 或打包不會更新名單時間。正式 Python 連網名單改用 TWSE ISIN `strMode=2/4`、CFI `ES` 分類；Flutter 直連則使用官方發行公司 JSON、未逐筆 CFI 認證，三者不能混為同一份最新核證清單。

## 搜尋與市場代碼

| 查詢例 | 標準代碼 |
|---|---|
| `2330`、`2330.TW`、`台積電`、`TSMC` | `2330.TW` |
| `6488`、`6488.TWO`、`環球晶` | `6488.TWO` |
| `輝達`、`Nvidia`、`NVDA` | `NVDA` |
| `特斯拉`、`Tesla` | `TSLA` |
| `BRK.B`、`BRK-B`、`Berkshire Hathaway` | `BRK-B` |

搜尋同時涵蓋兩市場；選台灣上市／上櫃標的使用 TWD 本金，選美股使用 USD 本金，不合併幣別。數字台股代碼必須由字典／來源確認上市或上櫃後決定後綴，不能一律附 `.TW`。美股股份類別採 Yahoo 可解析的 `-` 格式。

選取已有行情的本頁推薦可開啟計算機；只有身分資料的結果帶入持股表單，等待實際成本、股數與初始停損。字典沒有價格、ADR、RS 或確認突破；不能因搜尋命中就建立買進建議。

## 主檔、檢索器與同步

- `stocks_master.json`：Flutter 打包的共同搜尋 asset。
- `stocks_master_sources.json`：當前字典的數量、分類與不同來源日期。
- `metadata_snapshots/`：可重建的來源快照及雜湊／固定來源識別。
- `stock_search.js`、`lib/services/stock_search_service.dart`：同等規則的 JS／Dart 本機索引。
- `lib/widgets/stock_search_field.dart`：共用防抖與選取介面。
- `scripts/sync_stock_search.py`：將同一主檔同步嵌入 HTML；同步後需重建 APK 才會更新安裝的 Flutter asset。

每列包含 `market, symbol, code, name_zh, name_full_zh, name_en, abbr_en, aliases, short_codes`。未核實的法律全名或翻譯保持空值／透明來源名稱，不自造中文譯名。

排序優先為代碼完全匹配、名稱／別名完全匹配、代碼前綴、名稱前綴、子字串，再做有界拼字容錯。全形轉半形、大小寫及常見標點正規化不改變標準代碼。鍵盤上下選擇、Enter 確認、Escape 關閉，也支援點擊。每次輸入只查記憶體索引，不下載股票池。

## 離線重建與正式來源刷新

只用隨包來源重建同一批身分資料，**不會取得最新名單**：

```bash
python3 scripts/import_bundled_metadata.py
python3 scripts/sync_stock_search.py
python3 scripts/sync_stock_search.py --check
node scripts/check_stock_search.cjs
```

需要當下公開來源時，先安裝後端依賴，檢查可用選項：

```bash
python3 scripts/refresh_stock_metadata.py --help
python3 scripts/refresh_stock_metadata.py --market all
```

嚴格刷新遇到來源不完整或美股保守分類限制時可能拒絕覆寫。讀完來源警告並接受該限制後，才明確執行 `python3 scripts/refresh_stock_metadata.py --market all --allow-partial`。該選項不是分類認證，也不會將未知證券偷偷加入普通股。刷新後執行同步並重建 APK，保留來源檔與警告。別名可隨標準代碼保留，已不在新範圍的歷史身分不應硬留成當日成員。

搜尋字典擴充不等於行情全市場掃描。Flutter 直連仍是最多 30 檔核心／指定個股；全池逐頁評估須選 Python API，查看本頁與累積覆蓋數。當頁 RS 不是全市場排名，詳見 [ALL_STOCKS_UPDATE.md](ALL_STOCKS_UPDATE.md)。

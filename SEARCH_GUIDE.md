# 台美股離線智慧搜尋

儀表板與新增／編輯持股支援代碼、中英文名稱、別名及簡碼。輸入後等待 200ms，顯示最多 8 筆結果，每列有 TW／US、市場標準代碼、中文名與英文名。鍵盤 ↑／↓ 選取、Enter 確認、Escape 關閉；也可直接點擊結果。

| 輸入範例 | 標準代碼 |
|---|---|
| `2330`、`2330.TW`、`台積電`、`TSMC`、`TJD` | `2330.TW` |
| `長榮海運`、`Evergreen Marine`、`2603` | `2603.TW` |
| `聯發科`、`MediaTek`、`LFK` | `2454.TW` |
| `NVDA`、`Nvidia`、`NVIDIA Corporation`、`輝達`、`輝達半導體` | `NVDA` |
| `特斯拉`、`Tesla, Inc.` | `TSLA` |
| `蘋果`、`Apple Inc.` | `AAPL` |
| `微軟`、`Microsoft` | `MSFT` |
| `BRK.B`、`BRK-B`、`Berkshire Hathaway` | `BRK-B` |

搜尋可跨市場：在台股畫面選取輝達，會使用美股 USD 帳戶；選取台積電，使用台股 TWD 帳戶。既有獨立 Capital 設定保持各自儲存。選取已有行情的推薦，可開啟部位計算；只有字典身分資料的股票，會帶入持股表單並提示輸入成本／股數／初始停損。字典不提供價格、ADR 或已確認突破；離線未知行情需明確手動输入，API 模式可在儲存持股後取得報價。

## 資料與實作

- `stocks_master.json`：唯一的共同元資料主檔。Flutter 將它打包為 asset；兩份 HTML 內嵌相同 JSON，雙擊離線即可搜尋。包含完整公開 S&P 500 快照、主要美股補充與常見台股；來源及記錄筆數見 `stocks_master_sources.json`。成分股會變更，快照不表示永久即時名單。沒有已核對的中文譯名／法律全名時欄位保持空字串，介面以已知名稱顯示。
- `stock_search.js`：無套件 JavaScript 核心，支援瀏覽器與 Node。
- `lib/services/stock_search_service.dart`：Dart 同等檢索器，預先計算比較欄位，asset 單次載入；不會每次輸入都呼叫行情 API。
- `lib/widgets/stock_search_field.dart`：Flutter 共用防抖搜尋欄位。
- `scripts/sync_stock_search.py`：把主字典與同一 JS 引擎同步嵌入 `preview/index.html`／`standalone_preview.html`。

每列 schema：

```json
{
  "market": "TW",
  "symbol": "2330.TW",
  "code": "2330",
  "name_zh": "台積電",
  "name_full_zh": "台灣積體電路製造股份有限公司",
  "name_en": "Taiwan Semiconductor Manufacturing Co.",
  "abbr_en": "TSMC",
  "aliases": ["臺積電", "Taiwan Semiconductor"],
  "short_codes": ["TJD"]
}
```

正規化將全形 ASCII 轉半形、英文轉小寫，去除空白與標點，保留字母、數字及中文。數字台股 `code` 同時索引，`.`／`-` 差異不影響搜尋；回傳始終是資料源用的標準代碼，例如 `.TW` 或 `BRK-B`。

| 匹配規則（優先順序） | 分數 |
|---|---:|
| 代碼完全相符 | 10000 |
| 名稱／別名／简碼完全相符 | 9000 |
| 代碼前綴 | 8000 |
| 名稱／別名前綴 | 7000 |
| 代碼子字串 | 6000 |
| 名稱／別名子字串 | 5000 |
| 輸入包含完整索引值（至少 3 字元） | 3000 |
| 有界 Levenshtein 拼字容錯 | 1000 − 編輯距離 × 100 |

容錯僅處理 3～32 字元的查詢：3～5 字元最多 1 次編輯，6 字元以上最多 2 次。完全／前綴／子字串匹配優先，避免拼字推測蓋過代碼。相同分數以標準代碼、市場排序，順序不依賴原始字典排列。JavaScript 與 Dart 各有最多 128 筆記憶體查詢快取。

## JavaScript 使用

```javascript
// Browser: embed stock_search.js and JSON before the UI, as the previews do.
const rows = JSON.parse(document.getElementById('stocks-master').textContent);
const index = StockSearch.setStocksMaster(rows);
const results = StockSearch.searchStock('輝達');
// results[0].symbol === 'NVDA'; no price/indicator is inferred.
const taiwanOnly = index.searchStock('台', {market: 'TW', limit: 8});
```

Node 可用 `require('./stock_search.js')` 與 `require('./stocks_master.json')` 建立同一索引。手動新增字典列後，執行：

```bash
python3 scripts/sync_stock_search.py
python3 scripts/sync_stock_search.py --check
node scripts/check_stock_search.cjs
node scripts/check_preview_ui.cjs
node scripts/check_portfolio_preview.cjs
node scripts/check_standalone_preview.cjs
```

可用 `python3 scripts/refresh_stock_metadata.py --help` 查看整批更新最新 S&P 500／TWSE 名單的方法。這是維護操作，需要網路與後端依賴；使用者搜尋時始終只查記憶體。更新保留已建立的別名，更新後需同步 HTML。Flutter 的中文字型是已隨包附上的離線子集；若新增中文字而字型缺字，在具備本機 Noto CJK 與 fontTools 的開發環境執行 `python3 scripts/prepare_preview_font.py` 重產生。

GitHub Actions 已納入字典同步、JS 排序、離線 UI 檢查及 Flutter 單元／Widget 測試。本沙箱沒有 Flutter SDK；這裡可執行 JS／Python 檢查，Dart 分析、Widget 測試與 APK 建置以 Actions 實際結果為準。

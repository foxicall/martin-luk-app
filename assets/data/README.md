# 股票產業分類資料快照

本資料快照於 2026-10-29（UTC）完成，共涵蓋 App 股票清單的 7,091 檔標的。資料可直接以 JSON 或 CSV 讀取。

| 市場 | 總數 | 已分類 | Unknown | 待處理 |
| --- | ---: | ---: | ---: | ---: |
| 台股 | 1,978 | 1,978 | 0 | 0 |
| 美股 | 5,113 | 5,098 | 15 | 0 |

台股來源為 TWSE（1,085 檔）、TPEx（892 檔）及 Yahoo Finance（1 檔）；美股來源為 Yahoo Finance。Yahoo 的 sector、industry 保留原文；人工補充的產業與主題可由來源欄位及 custom_themes.json 辨識。

15 檔美股的 sector 與 industry 明確設為 Unknown，並保留原因：14 檔回傳 HTTP 404，TVC 未提供 sector。Unknown 不計入成功分類數。完成處理不代表每檔都有可取得的產業資料。

## 檔案

- `assets/data/stock_industries.json`：以台股四碼代號或美股 ticker 為 key 的分類映射，包含來源、時間戳與分類狀態。
- `metadata_snapshots/stock_industries.csv`：相同資料的 CSV 匯出。
- `metadata_snapshots/industry_cache.snapshot.json`：完成時的來源快取檢查點，包含官方批次資料、逐股快取與終止狀態。
- `metadata_snapshots/custom_themes.json`：人工產業細分與主題標籤規則。
- `metadata_snapshots/us_taxonomy_run_report.json`：最終美股續補報告，包含原有 64 筆快取、續補 5,049 筆及完成狀態；其中 PID 為歷史紀錄。
- `metadata_snapshots/failed_tickers.log`：上述 15 檔 Unknown 的稽核紀錄。
- `stocks_industry_sources.json`：資料來源及市場覆蓋摘要。
- `metadata_snapshots/industry_data.sha256`：本次上傳資料與此說明的獨立校驗清單。

此分支提供分類資料快照。將資料接入現有 App 的資產宣告與讀取流程，仍需另行整合。

## 讀取與校驗

取得此分支的 Git checkout 後，在專案根目錄執行：

```bash
sha256sum -c metadata_snapshots/industry_data.sha256
```

```python
import json
from pathlib import Path

industries = json.loads(Path('assets/data/stock_industries.json').read_text(encoding='utf-8'))
print(industries['2330'])
print(industries['NVDA'])
```

Git checkout 可取得完整資料及校驗檔。專案的 App 封裝流程另有檔案篩選規則，驗證此資料快照請使用 Git checkout。

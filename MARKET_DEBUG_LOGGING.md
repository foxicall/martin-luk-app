# Android 行情日誌

`lib/services/market_data_api.dart` 使用 Flutter `debugPrint`，不需要新建傳輸依賴檔案。以下訊息在安裝修改後的 APK 並觸發更新時產生：

```text
[MarketAPI] [LOAD] NVDA 週期: 1d，強制更新: true
[MarketAPI] >>> 開始抓取: NVDA
[MarketAPI] [REQUEST] NVDA 端點: query1.finance.yahoo.com，週期: 1d，嘗試: 1/2
[MarketAPI] <<< 標的 NVDA 狀態碼: 200
[MarketAPI] [SUCCESS] NVDA 取得成功 (價格: …, K線筆數: …)
```

上面是格式示意，不是本次取得的真實行情。非 200 會有 `[ERROR]`、HTTP 狀態及本文前 200 個 Unicode 字元；真正逾時會有 `[TIMEOUT]`，其他例外包含型別、股票、週期、端點與 `http`／`json`／`chart` 階段。HTTP 200 的 HTML／驗證頁也會印出受限本文。快取成功會額外標記 `[CACHE]` 與原始報價時間，不能當成新下載的即時行情。

## 查看 Android 日誌

在 Android Studio Logcat 搜尋 `MarketAPI`。若電腦已具備 ADB，可在 Windows 終端執行：

```bat
adb logcat -v time | findstr /L /C:"[MarketAPI]"
```

Linux／macOS：

```bash
adb logcat -v time | rg '\[MarketAPI\]'
```

在手機按更新後，保留該次從 `[LOAD]` 或 `>>>` 到成功／錯誤的內容。不要清空既有日誌。`debugPrint` 是控制台日誌，不會自動出現在手機畫面；已安裝的舊 APK 也不會因修改 GitHub 原始碼而更新。

## 判讀

- 只有 `>>>`，沒有 `<<<`：仍在等待連線或回應標頭，應接著出現逾時／取消錯誤。
- 已有 `<<<`，沒有 `[SUCCESS]`：查看是否本文下載卡住，或 `json`／`chart` 階段出錯。
- 已有 `[SUCCESS]`，畫面仍轉圈：行情已解析，應繼續查控制器／畫面更新或安裝的版本。
- `[ERROR] HTTP 403`：供應商仍拒絕該端點，標頭不能保證解除拒絕。
- `[CACHE]`：保留舊資料，檢查其原始時間及是否過期。

ADR、EMA、RS、風控與進出場計算維持原規則；新增日誌不會製造行情或推薦。

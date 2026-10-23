# Claude-Scripts

Claude Code 相關的 Windows 小工具。

## share-claude-projects.ps1

讓多個 VS Code profile（各自登入不同 Claude 帳號）共用同一份 session 紀錄。

### 背景

每個 VS Code profile 可以在 `settings.json` 裡為 Claude Code 指定自己的 config 目錄：

```jsonc
"claudeCode.environmentVariables": [
    { "name": "CLAUDE_CONFIG_DIR", "value": "C:\\Users\\<you>\\.claude-xxx" }
]
```

登入的帳號、設定、session 都存在這個目錄裡，所以不同 profile 彼此看不到對方的 session。
Session 紀錄（`*.jsonl`）和每個專案的 memory 都放在 `<config 目錄>\projects\` 底下。

### 運作方式

```
~\.claude\projects        ← 真正存檔的地方（共用來源，預設是 Default profile）
~\.claude-alt\projects    → junction 指向 ~\.claude\projects
~\.claude-work\projects   → junction 指向 ~\.claude\projects
...
```

1. 自動找出所有 profile 對應的 config 目錄：
   - VS Code、VS Code Insiders、Cursor、VSCodium 的 Default 與各 profile 的 `settings.json`
   - 沒有任何 profile 對應的 `~\.claude*` 資料夾
2. 把各目錄裡要共用的子資料夾（預設 `projects`）合併到共用來源。
   - 只複製、不覆蓋；同名但內容不同的檔案另存為 `*.from<目錄名>.*`。
3. 原資料夾改名為 `<子資料夾>.bak-<時間>` 保留。
4. 建立 directory junction 指向共用來源（不需要系統管理員權限）。

只有指定的子資料夾會共用；帳號登入（`.claude.json`）、`settings.json` 等仍然各 profile 獨立。

### 需求

- Windows、PowerShell 7（`pwsh`）
- 執行 `-Share` / `-Unshare` 前，**關掉所有 Claude 對話**。
  偵測到 `claude.exe` 還在跑時 script 會直接停止（可用 `-Force` 略過檢查，不建議）。

### 用法

```powershell
$s = 'D:\Claude-Scripts\share-claude-projects.ps1'

pwsh -File $s -Status                         # 查看各 profile 目前的狀態
pwsh -File $s -DryRun                         # 預覽會做什麼，不改任何檔案
pwsh -File $s                                 # 分享 projects
pwsh -File $s -Items projects,file-history    # 同時分享 file-history（rewind 用的檔案備份）
pwsh -File $s -Unshare                        # 取消分享，各 profile 拿回一份自己的副本
pwsh -File $s -RemoveBackups                  # 確認沒問題後刪除 *.bak-* 備份
```

| 參數 | 說明 |
|---|---|
| `-Status` | 列出每個 config 目錄、對應的 profile 名稱、共用狀態與 session 數 |
| `-Unshare` | 移除 junction，把目前共用的內容完整複製回各 profile（共用來源保留） |
| `-RemoveBackups` | 刪除 `<子資料夾>.bak-*` |
| `-Items` | 要共用的子資料夾，逗號分隔，預設 `projects` |
| `-ConfigDirs` | 只處理這些 config 目錄（不自動偵測），逗號分隔 |
| `-SharedDir` | 共用來源的 config 目錄，預設 `~\.claude` |
| `-DryRun` | 只顯示動作，不改檔案 |
| `-Force` | 略過「claude.exe 正在執行」的檢查 |

重複執行是安全的：已經共用的會跳過，指向其他位置的 junction 會警告後保持不動。

### 新增 profile 時

1. 在新 profile 的 `settings.json` 設好 `CLAUDE_CONFIG_DIR`。
2. 關掉所有 Claude 對話，再執行一次 `pwsh -File $s`。

### 注意事項

- **同一個 session 不要同時在兩個視窗開**，兩邊同時寫入同一個檔案，紀錄會亂掉。不同 session 同時開沒問題。
- Memory（`projects\<專案>\memory\`）也會一起共用，每個 profile 看到的專案規則相同。
- 用 A 帳號 resume B 帳號開的 session，之後的用量算在目前登入的 A 帳號上。
- 輸入框 ↑ 的歷史（`history.jsonl`）是單一檔案，不在共用範圍內。

### 手動還原單一 profile

```powershell
cmd /c rmdir C:\Users\<you>\.claude-alt\projects     # 只移除 junction，不會刪到共用檔案
Rename-Item C:\Users\<you>\.claude-alt\projects.bak-<時間> projects
```

> 不要用檔案總管或 `Remove-Item -Recurse` 刪 junction，有機會連共用來源的內容一起刪掉。

### 搬移 / 改名專案資料夾

Claude Code 依專案路徑存放 session，例如
`D:\Claude-Scripts` → `~\.claude\projects\d--Claude-Scripts\`（非英數字元都換成 `-`）。
專案資料夾改名或搬家後，在關掉該專案的 Claude 對話後，把對應的 session 資料夾一起改名即可：

```powershell
Rename-Item "$env:USERPROFILE\.claude\projects\d--Old-Name" d--New-Name
```

Session 內部記錄的工作目錄仍是舊路徑，resume 後對話裡出現的路徑以新位置為準。

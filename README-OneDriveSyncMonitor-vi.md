# OneDrive Sync Monitor cho Windows

## Cách hoạt động

Monitor chạy bằng tài khoản Windows đang đăng nhập. Mỗi 60 giây, nó đọc trạng thái `OneDrive.exe`, thư mục đồng bộ và file `SyncDiagnostics.log` của OneDrive. Các tình huống được phát hiện gồm:

- OneDrive không chạy hoặc không phản hồi.
- Thư mục đồng bộ biến mất, tài khoản đăng nhập lỗi, OneDrive tự báo sync/scan bị stall.
- Số file upload/download lỗi hoặc cảnh báo tăng.
- Có thay đổi local đang chờ nhưng các chỉ số upload/download không tiến triển trong 15 phút.

Khi lỗi xuất hiện, lỗi mới tăng, lỗi hồi phục hoặc đến kỳ nhắc lại, monitor gửi một HTTP POST tới Power Automate. Payload có thẻ Teams Adaptive Card cùng `computer`, `status`, `timestampUtc`, `text`, `issues` và `recipient`. Giá trị `recipient` là `it@aspectengineering.com.au`; flow phải có hành động gửi mail thật tới địa chỉ này. Nếu webhook chưa được cấu hình hoặc mạng mất, cảnh báo nằm trong log và sẽ thử gửi lại khi kết nối trở lại. Tool không tự sửa file hay restart OneDrive.

## Kiểm thử trước khi cài

Mở PowerShell trong thư mục bộ cài và chạy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-OneDriveSyncMonitor.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\OneDriveSyncMonitor.ps1 -Once -LogPath "$env:TEMP\OneDriveMonitor-check.log" -StatePath "$env:TEMP\OneDriveMonitor-check-state.json"
```

Lệnh đầu giả lập trạng thái khỏe, upload lỗi, sync đứng, OneDrive tắt, hồi phục và mất kết nối webhook. Không gửi email/Teams thật. Lệnh thứ hai đọc OneDrive thật trên máy này và ghi log/state kiểm thử trong `%TEMP%`.

## Tạo nơi nhận cảnh báo trong Teams và email IT

1. Trong Microsoft Teams, tới team/channel nhận cảnh báo, chọn `...` → **Workflows** → mẫu **Send webhook alerts to a channel**. Lưu flow và sao chép URL webhook.
2. Mở flow trong Power Automate. Đảm bảo trigger **When a Teams webhook request is received** cho phép lời gọi bằng URL webhook từ monitor (tùy chọn `Anyone` nếu tenant cho phép). Mẫu này đăng thẻ Teams Adaptive Card từ payload vào channel.
3. Trước hành động **Office 365 Outlook → Send an email (V2)**, thêm Condition: `@equals(triggerBody()?['sendEmail'], true)`. Nhánh Yes gửi tới `it@aspectengineering.com.au`; nhánh No bỏ qua email. Menu tray điều khiển email bằng cờ `sendEmail`.
4. IT nên là owner/co-owner của flow để cảnh báo không phụ thuộc vào một tài khoản cá nhân.

URL webhook là bí mật của flow. Chỉ dán vào màn hình cài đặt trên máy cần theo dõi; không đưa vào email hoặc tài liệu công khai. Hành động Outlook gửi mail bằng account đã kết nối trong Power Automate.

Trên tenant hiện tại đã tạo flow [OneDrive Sync Monitor - AES-VN-DUY](https://make.powerautomate.com/environments/Default-a2f1a70f-1bf7-48c7-9b0f-c0d3f912a76e/flows/b01f149b-dc1e-4e90-924f-1865d2932a6f/details), đăng lên channel **IT Team → IT mailbox** và gửi email tới địa chỉ IT nêu trên. URL webhook đã được lưu mã hóa riêng trên máy `AES-VN-DUY`, không đóng gói trong ZIP. Khi cài máy khác, lấy URL từ flow theo quyền truy cập của bạn và dán lúc cài.

Tài liệu Microsoft: [Tạo Teams webhook bằng Workflows](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook), [Send an email (V2)](https://learn.microsoft.com/en-us/connectors/office365/).

## Cài đặt và tự cập nhật

### Bộ cài một file cho máy khác

Với bản thử 1.2.7, dùng ZIP `OneDriveSyncMonitor-Setup-v1.2.7.zip`, giải nén rồi chạy `OneClick-Setup.cmd` bằng **tài khoản Windows sẽ dùng phần mềm**. Bộ cài EXE cũ 1.2.2 chưa có lựa chọn thư viện SharePoint. Installer dừng các instance của chính phần mềm trong thư mục cài của user hiện tại, thay các mục tự khởi động cũ, rồi khởi chạy bản mới; nó không dừng PowerShell hoặc OneDrive không liên quan. Cấu hình và log được giữ lại. Nếu backup Graph trước đó đang bật, installer thử bật lại sau nâng cấp; nếu xác thực thất bại, nó cảnh báo và để backup tắt. Installer dùng Startup của user nếu chính sách máy chặn tạo Scheduled Task. Giữ cửa sổ cài đặt mở cho đến khi báo hoàn tất. Bản thử chưa được phát hành thành GitHub Release; nâng cấp từ v1.2.3 cần dùng ZIP mới để nhận helper chứng chỉ.

Sau khi cài, biểu tượng OneDrive Sync Monitor xuất hiện ở vùng khay hệ thống cạnh đồng hồ. Nhấp đúp icon để mở log; nhấp phải để xem trạng thái, gửi test alert, bật/tắt mục **Gửi email IT**, mở thư mục dữ liệu, khởi động lại monitor hoặc ẩn icon. Chọn “Ẩn icon và tiếp tục chạy nền” chỉ đóng giao diện; monitor vẫn chạy. Chọn “Thoát monitor và icon” mới dừng cả monitor.

Bộ cài sẽ hỏi URL webhook Power Automate. URL không nằm trong EXE, nên phải lấy từ flow của công ty và dán riêng trên mỗi máy. Nếu bỏ trống, tool vẫn ghi log local nhưng **không gửi cảnh báo tới IT**. Sau khi cài, wizard gửi một cảnh báo `TEST ONLY`; kiểm tra Teams **và** email IT trước khi tin vào cảnh báo tự động. Mỗi máy mặc định dùng tên máy Windows của chính nó.

Wizard cũng hỏi có thiết lập sao lưu trực tiếp bằng Microsoft Graph hay không. Nếu chọn, máy cần `Microsoft.Graph.Authentication`. Với thư viện SharePoint, ưu tiên ứng dụng Entra + chứng chỉ riêng của máy (hướng dẫn bên dưới); cách này không cần đăng nhập `archive` khi watcher chạy nền. Chọn **SharePoint document library** cho nguồn `Design - Documents`; không chọn OneDrive cá nhân. Wizard xác minh site và thư viện từ URL trước khi lưu cấu hình. Chỉ bật sao lưu tự động sau khi thử **một file mẫu mới**, xác nhận đường dẫn cloud đúng. Nếu bỏ qua, monitor vẫn chạy nhưng sao lưu Graph chưa bật. Không đưa private key vào ZIP hoặc sao chép sang máy khác.

Ô kiểm thử tải file cần đường dẫn **tương đối của một file mẫu mới bên trong thư mục nguồn đã chọn**, ví dụ `Test-IT\probe.txt`. Không nhập đường dẫn ổ đĩa như `Z:\`. Nhấn Enter để bỏ qua; monitor và cảnh báo vẫn hoạt động, còn sao lưu Graph chưa bật. Trước khi thử tải file, xác nhận email tài khoản Graph và URL thư viện được in ra đúng đích cần dùng.

EXE được tạo bằng IExpress có sẵn trong Windows và hiện **chưa được ký mã**. Nếu chính sách công ty chặn EXE chưa ký, nhờ IT kiểm tra/ký hoặc dùng bộ ZIP; không tắt SmartScreen hay chính sách bảo mật để chạy. Tạo lại EXE từ mã nguồn bằng `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-OneClickInstaller.ps1`. Auto-update chương trình sau cài vẫn dùng GitHub Release và checksum như bên dưới.

Giải nén bộ cài vào một thư mục, sau đó nhấp đúp `Setup-OneDriveSyncMonitor.cmd`. Dán URL webhook khi được hỏi; có thể để trống và cấu hình sau. Installer ưu tiên Task Scheduler; nếu chính sách máy chặn tạo task, nó dùng mục Startup của user Windows hiện tại. Cả hai cách đều tự chạy khi user đăng nhập.

Cách cài bằng PowerShell và đặt mã máy riêng:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-OneDriveSyncMonitor.ps1 -ComputerName 'LAPTOP-IT-01' -PromptForWebhook
```

Nếu không chọn `-ComputerName`, cảnh báo dùng tên Windows hiện tại. Bộ cài nằm tại `%LOCALAPPDATA%\OneDriveSyncMonitor`; log tại `monitor.log`, trạng thái gần nhất tại `state.json`. URL webhook được mã hóa bằng Windows DPAPI cho đúng user Windows đã cài.

Bản phát hành có version trong `version.json`. Với cấu hình **không dùng chứng chỉ**, monitor mặc định kiểm tra GitHub Release tối đa mỗi 24 giờ. Nếu có version mới hơn, nó tải ZIP bộ cài (có thể có số phiên bản trong tên), kiểm tra SHA-256 từ asset `.sha256` tương ứng, chờ tiến trình hiện tại thoát, cập nhật các file chương trình và khởi động lại monitor. `config.json`, `state.json`, `monitor.log` và webhook mã hóa không bị ghi đè. Có thể tắt bằng:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-OneDriveSyncMonitor.ps1 -DisableAutoUpdate
```

Để bật lại auto-update trên máy đã cài, chạy `Install-OneDriveSyncMonitor.ps1 -EnableAutoUpdate`. Với cấu hình **không dùng chứng chỉ**, monitor sẽ kiểm tra GitHub Release theo chu kỳ 24 giờ, kiểm tra checksum rồi cập nhật script và tray app. Khi cập nhật, updater tạm dừng tray app, thay file, rồi khởi động lại tray app. Với backup dùng chứng chỉ, tự cập nhật mã bị **chặn dù cờ auto-update đang bật**: checksum đặt cùng GitHub Release không đủ để xác thực mã chạy với khóa riêng. IT cần kiểm tra nguồn phát hành và cài bản mới thủ công cho đến khi có cơ chế ký độc lập.

Không đưa GitHub token vào máy cài đặt. Vì vậy repo chứa bản release tự cập nhật phải cho phép máy theo dõi tải asset công khai; secret webhook không nằm trong repo hoặc file ZIP.

## Thử gửi cảnh báo thật

Sau khi cài và dán URL webhook, chạy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\OneDriveSyncMonitor\OneDriveSyncMonitor.ps1" -TestAlert
```

Thông báo có chữ `TEST ONLY` và tên máy. Kiểm tra cả channel Teams, hộp thư `it@aspectengineering.com.au` và lịch sử chạy flow. `-TestAlert` không đổi trạng thái OneDrive thật. Trường `recipient` trong JSON không tự gửi email; Condition `sendEmail` trong flow quyết định có gửi email hay không.

## Sao lưu trực tiếp lên OneDrive khi ứng dụng sync lỗi

`OneDriveCloudBackup.ps1` giữ đường dẫn tương đối dưới thư mục SharePoint local và dùng Microsoft Graph để khôi phục thay đổi một phía đã có mốc xác minh: local thay đổi còn cloud giữ mốc cũ thì push lên cloud; cloud thay đổi còn local giữ mốc cũ thì pull về local. Graph delta được kiểm tra theo chu kỳ để phát hiện thay đổi từ cloud ngay cả khi Windows không tạo event local. Nếu cả local và cloud đều thay đổi, hoặc file chỉ tồn tại một phía nhưng chưa có mốc chung, tool không chọn theo timestamp, không ghi đè, không xóa file; nó ghi conflict để IT xử lý. File online-only (Files On-Demand) bị bỏ qua để không hydrate thư viện lớn ngoài ý muốn.

Chế độ này cần đăng nhập tài khoản Microsoft 365 một lần với quyền Graph `Files.ReadWrite`. Chạy trên máy đã cài monitor:

```powershell
powershell.exe -NoProfile -Command "Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\OneDriveSyncMonitor\OneDriveCloudBackup.ps1" -Setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\OneDriveSyncMonitor\OneDriveCloudBackup.ps1" -Once -RelativePath 'Documents\example.docx'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\OneDriveSyncMonitor\OneDriveCloudBackup.ps1" -Enable
```

Lệnh `-Setup` lấy thư mục Business1, tenant và email từ cấu hình OneDrive của Windows, yêu cầu đăng nhập đúng tài khoản đó rồi xác nhận drive cloud. `-Once -RelativePath` thử riêng một file; `-Enable` theo dõi các lần lưu tiếp theo mà không tải hàng loạt file cũ. Sau khi bạn lưu thay đổi mới, tool tải lên đúng đường dẫn nếu phiên bản cloud chưa bị người khác sửa. Nếu phát hiện xung đột hoặc tải lên thất bại, tool giữ file local, báo Teams/email IT qua webhook monitor và thử lại ở vòng sau. Tool chạy khi user Windows đăng nhập và tự nạp script mới sau cập nhật release.

Đối với thư viện SharePoint `Design - Documents`, dùng URL `https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents/Forms/AllItems.aspx` và nguồn local `D:\Users\qqqq\aspectengineering.com.au\Design - Documents`. Chế độ cũ `-SetupSharePoint` dùng tài khoản Business1 với quyền delegated `Files.ReadWrite.All`, `Sites.Read.All`; nó có thể cần đăng nhập lại và không phù hợp để cam kết chạy nền không gián đoạn.

### Sao lưu SharePoint chạy nền bằng ứng dụng Entra + chứng chỉ

IT tạo **app registration riêng** trong đúng tenant, cấp Microsoft Graph **Application** permission `Sites.Selected` và admin consent. Sau đó cấp ứng dụng vai trò `write` trên **site Design** (không phải toàn bộ SharePoint) theo [hướng dẫn selected permissions của Microsoft](https://learn.microsoft.com/en-us/graph/permissions-selected-overview). Quyền `Sites.Selected` một mình chưa đủ: phải có cả site grant. Việc này cho phép ứng dụng ghi trong site Design; nếu cần giới hạn tới riêng document library, cần thiết kế `Lists.SelectedOperations.Selected` riêng trước khi cấp quyền.

Trên từng máy, chạy helper bằng **đúng Windows user sẽ chạy watcher**. Helper tạo khóa riêng không export được trong `Cert:\CurrentUser\My` và chỉ xuất chứng chỉ công khai `.cer`:

```powershell
$p = "$env:LOCALAPPDATA\OneDriveSyncMonitor"
& "$p\New-CloudBackupCertificate.ps1" -PublicCertPath "$env:USERPROFILE\Desktop\OneDriveCloudBackup-$env:COMPUTERNAME.cer"
```

IT tải file `.cer` công khai lên **Certificates & secrets** của app registration; không gửi private key/PFX. Ghi lại tenant ID, app (client) ID và thumbprint do helper in ra. Sau khi IT đã cấp site grant, chạy trên máy cần sao lưu:

```powershell
& "$p\OneDriveCloudBackup.ps1" -SetupSharePoint `
  -SharePointLibraryUrl 'https://aspectengwa.sharepoint.com/sites/Design/Shared%20Documents/Forms/AllItems.aspx' `
  -SourceRoot 'D:\Users\qqqq\aspectengineering.com.au\Design - Documents' `
  -TenantId '<tenant-guid>' -ClientId '<app-guid>' -CertificateThumbprint '<thumbprint>'
```

Lệnh thiết lập chỉ đọc Graph để xác minh **đúng site và document library**, lưu cấu hình nhưng **không bật tự động**. Tạo một file mẫu mới bên trong nguồn, chạy `& "$p\OneDriveCloudBackup.ps1" -Once -RelativePath 'Test-IT\probe.txt' -NoAlerts`, kiểm tra `uploaded=1, failed=0` và file xuất hiện ở đúng thư viện/đường dẫn SharePoint. Chỉ sau đó chạy `& "$p\OneDriveCloudBackup.ps1" -Enable` và kiểm tra watcher trong một phiên Windows mới. Nếu kiểm tra quyền hoặc chứng chỉ thất bại, giữ backup tắt và nhờ IT xử lý; không cấp quyền tenant-wide `Sites.ReadWrite.All` cho tiện.

Để lập mốc an toàn cho file đã có từ trước, IT có thể dùng `-Once -Repair -BaselineAll -NoAlerts`. Lệnh này chỉ đối chiếu các file local đã có nội dung: file giống cloud thì được nhận mốc; file khác nhau hoặc chỉ có một phía được báo conflict, không copy hàng loạt. Thư mục lớn có thể cần rất nhiều lệnh Graph và thời gian dài; nên kiểm tra phạm vi trước khi chạy. Chế độ cũ `-BaselineAll -Backfill` là migration một chiều có chủ đích, không dùng cho thư viện 400 GB hoặc để tự chọn bên thắng.

Trạng thái cloud backup nằm ở `%LOCALAPPDATA%\OneDriveSyncMonitor\cloud-backup-state.json`; log ở `cloud-backup.log`. Watcher dùng chứng chỉ kiểm tra lại kết nối Graph khoảng mỗi 10 phút kể cả khi không có file mới; lỗi xác thực/quyền được ghi log và báo qua webhook monitor nếu webhook hoạt động. Không xóa file trạng thái khi đang dùng: nó giữ mốc phiên bản cloud để tránh ghi đè thay đổi của người khác. Cấu hình SharePoint mới dùng `SyncMode = BidirectionalRepair`. Có thể kiểm thử một file đã có mốc bằng `-Once -Repair -RelativePath 'folder\file.ext'`. `-Once -Repair -BaselineAll` chỉ kiểm kê an toàn: file chưa có mốc mà khác nhau sẽ báo conflict, không copy hàng loạt. Nếu IT đã kiểm tra và chủ động chọn bên đúng cho **một file cụ thể**, dùng `-Once -Repair -RelativePath 'folder\file.ext' -ResolveWith Local` để push local, hoặc `-ResolveWith Cloud` để pull cloud. Hai lệnh này chỉ hoạt động với đúng một đường dẫn, ghi `MANUAL-PUSHED`/`MANUAL-PULLED` vào log và không chạy nền. Xóa và đổi tên vẫn không được tự động nhân bản; nếu `-Once` báo lỗi, chưa chạy `-Enable`. Muốn dừng, chạy script với `-Disable`.

## Gỡ cài đặt

Trong ZIP đã giải nén hoặc thư mục `%LOCALAPPDATA%\OneDriveSyncMonitor`, chạy `OneClick-Uninstall.cmd` bằng **đúng Windows user đã cài**. Lệnh gỡ một-click dừng tiến trình của đúng bản cài này, xóa các mục tự khởi động và các file chương trình đã biết. `config.json`, `cloud-backup.json`, `state.json`, `cloud-backup-state.json`, log và chứng chỉ cá nhân vẫn được giữ để IT kiểm tra hoặc cài lại. Nó không gỡ ứng dụng Microsoft OneDrive.

Lựa chọn dùng PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-OneDriveSyncMonitor.ps1 -RemoveProgramFiles
```

Chỉ dùng `-RemoveFiles` khi muốn xóa **cả dữ liệu cấu hình, trạng thái và log** sau khi đã lưu chứng cứ; bộ gỡ một-click **không** dùng tùy chọn này.

## Giới hạn

Monitor chạy khi Windows user đang đăng nhập. Nếu máy tắt, ngủ hoặc mất mạng, nó không thể gửi cảnh báo ngay; cảnh báo sẽ chờ gửi khi máy chạy và kết nối lại. Chỉ số trong `SyncDiagnostics.log` là tín hiệu của OneDrive, không phải xác nhận từng file đã lên cloud. Hãy dùng lịch sử phiên bản/kiểm tra file trên OneDrive nếu cần xác nhận một file cụ thể.

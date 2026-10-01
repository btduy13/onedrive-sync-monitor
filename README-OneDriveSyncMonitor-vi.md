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
3. Thêm hành động **Office 365 Outlook → Send an email (V2)**. Điền **To** cố định: `it@aspectengineering.com.au`; **Subject**: `OneDrive sync monitor - AES-VN-DUY` (đổi theo máy nếu tạo flow riêng); **Body** dùng biểu thức `coalesce(triggerBody()?['text'], triggerBody()?['attachments']?[0]?['content']?['body']?[1]?['text'])`. Lưu flow.
4. IT nên là owner/co-owner của flow để cảnh báo không phụ thuộc vào một tài khoản cá nhân.

URL webhook là bí mật của flow. Chỉ dán vào màn hình cài đặt trên máy cần theo dõi; không đưa vào email hoặc tài liệu công khai. Hành động Outlook gửi mail bằng account đã kết nối trong Power Automate.

Trên tenant hiện tại đã tạo flow [OneDrive Sync Monitor - AES-VN-DUY](https://make.powerautomate.com/environments/Default-a2f1a70f-1bf7-48c7-9b0f-c0d3f912a76e/flows/b01f149b-dc1e-4e90-924f-1865d2932a6f/details), đăng lên channel **IT Team → IT mailbox** và gửi email tới địa chỉ IT nêu trên. URL webhook đã được lưu mã hóa riêng trên máy `AES-VN-DUY`, không đóng gói trong ZIP. Khi cài máy khác, lấy URL từ flow theo quyền truy cập của bạn và dán lúc cài.

Tài liệu Microsoft: [Tạo Teams webhook bằng Workflows](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook), [Send an email (V2)](https://learn.microsoft.com/en-us/connectors/office365/).

## Cài đặt và tự cập nhật

Giải nén bộ cài vào một thư mục, sau đó nhấp đúp `Setup-OneDriveSyncMonitor.cmd`. Dán URL webhook khi được hỏi; có thể để trống và cấu hình sau. Installer ưu tiên Task Scheduler; nếu chính sách máy chặn tạo task, nó dùng mục Startup của user Windows hiện tại. Cả hai cách đều tự chạy khi user đăng nhập.

Cách cài bằng PowerShell và đặt mã máy riêng:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-OneDriveSyncMonitor.ps1 -ComputerName 'LAPTOP-IT-01' -PromptForWebhook
```

Nếu không chọn `-ComputerName`, cảnh báo dùng tên Windows hiện tại. Bộ cài nằm tại `%LOCALAPPDATA%\OneDriveSyncMonitor`; log tại `monitor.log`, trạng thái gần nhất tại `state.json`. URL webhook được mã hóa bằng Windows DPAPI cho đúng user Windows đã cài.

Bản phát hành có version trong `version.json`. Monitor mặc định kiểm tra GitHub Release tối đa mỗi 24 giờ. Nếu có version mới hơn, nó tải `OneDriveSyncMonitor-Setup.zip`, kiểm tra SHA-256 từ asset `OneDriveSyncMonitor-Setup.zip.sha256`, chờ tiến trình hiện tại thoát, cập nhật các file chương trình và khởi động lại monitor. `config.json`, `state.json`, `monitor.log` và webhook mã hóa không bị ghi đè. Có thể tắt bằng:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-OneDriveSyncMonitor.ps1 -DisableAutoUpdate
```

Không đưa GitHub token vào máy cài đặt. Vì vậy repo chứa bản release tự cập nhật phải cho phép máy theo dõi tải asset công khai; secret webhook không nằm trong repo hoặc file ZIP.

## Thử gửi cảnh báo thật

Sau khi cài và dán URL webhook, chạy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\OneDriveSyncMonitor\OneDriveSyncMonitor.ps1" -TestAlert
```

Thông báo có chữ `TEST ONLY` và tên máy. Kiểm tra cả channel Teams, hộp thư `it@aspectengineering.com.au` và lịch sử chạy flow. `-TestAlert` không đổi trạng thái OneDrive thật. Nếu không thấy mail, kiểm tra hành động **Send an email (V2)** trong flow; trường `recipient` trong JSON không tự gửi email.

## Gỡ cài đặt

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-OneDriveSyncMonitor.ps1
```

Lệnh này gỡ task hoặc mục Startup và giữ log để IT xem lại. Có thể thêm `-RemoveFiles` khi muốn xóa cả file đã cài và log sau khi đã lưu chứng cứ.

## Giới hạn

Monitor chạy khi Windows user đang đăng nhập. Nếu máy tắt, ngủ hoặc mất mạng, nó không thể gửi cảnh báo ngay; cảnh báo sẽ chờ gửi khi máy chạy và kết nối lại. Chỉ số trong `SyncDiagnostics.log` là tín hiệu của OneDrive, không phải xác nhận từng file đã lên cloud. Hãy dùng lịch sử phiên bản/kiểm tra file trên OneDrive nếu cần xác nhận một file cụ thể.

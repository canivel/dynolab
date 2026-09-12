import Foundation

/// Progress and opt-in controls from background downloaders. Stale writers are never
/// presented as actively transferring. These processes are not owned by the UI.
public enum BackgroundDownloads {
    public static func read(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mlx-dyno/downloads"), now: Date = Date()) -> [String: DownloadManager.Progress] {
        var result: [String: DownloadManager.Progress] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [] where url.pathExtension == "json" {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 32768,
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = record["repository"] as? String,
                  let state = record["state"] as? String,
                  let timestamp = record["updated_at"] as? Double,
                  let total = (record["total_bytes"] as? NSNumber)?.int64Value, total > 0,
                  let bytes = (record["downloaded_bytes"] as? NSNumber)?.int64Value, bytes >= 0 else { continue }
            let id = "background:" + url.lastPathComponent
            var progress = DownloadManager.Progress(repository: id)
            progress.displayName = name
            progress.downloadedBytes = min(bytes, total)
            progress.totalBytes = total
            progress.isExternal = true
            progress.status = state
            progress.isPaused = state == "paused"
            progress.controlToken = record["control_token"] as? String
            progress.isFinished = state == "complete" || state == "interrupted" || state == "cancelled"
            progress.detail = record["detail"] as? String
            if state == "cancelled" { progress.error = "Cancelled · partial files kept on disk" }
            else if state == "interrupted" { progress.error = "Background download stopped before completion." }
            else if !["complete", "cancelled", "interrupted"].contains(state) && (now.timeIntervalSince1970 - timestamp > 15 || timestamp > now.timeIntervalSince1970 + 5) {
                progress.detail = "Progress unavailable · background downloader has not reported recently"
                progress.isStale = true
            }
            result[id] = progress
        }
        return result
    }
}

using System.Security.Cryptography;

namespace InkvoltPdf.Core;

/// <summary>Why a download wasn't kept.</summary>
public enum DownloadProblem
{
    /// <summary>No answer, a refusal or a broken connection.</summary>
    Network,
    /// <summary>The server sent more or less than the pinned size.</summary>
    WrongSize,
    /// <summary>The bytes aren't the pinned ones (SHA-256).</summary>
    WrongContent,
    /// <summary>The file couldn't be written on this PC.</summary>
    Disk,
}

public sealed class PinnedDownloadException(DownloadProblem problem, string message, Exception? inner = null) : Exception(message, inner)
{
    public DownloadProblem Problem { get; } = problem;
}

/// <summary>
/// A file downloaded only when the person asked, from a pinned https address, kept only when it has the pinned size and
/// SHA-256 (Tesseract and its language data, <see cref="TesseractStore"/>). It is written beside its destination as
/// <c>.part</c> and moved into place once checked, so a file that is there is whole and the pinned one; nothing is sent
/// but the request for the file.
/// </summary>
public static class PinnedDownload
{
    public static async Task FetchAsync(HttpClient http, Uri url, long size, string sha256, string destination,
        IProgress<long>? progress = null, CancellationToken cancel = default)
    {
        if (url.Scheme != Uri.UriSchemeHttps) throw new ArgumentException("Pinned downloads are https only.", nameof(url));
        var part = $"{destination}.{Guid.NewGuid():N}.part"; // its own: two downloads of one file never write into each other
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            HttpResponseMessage response;
            try
            {
                response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, cancel).ConfigureAwait(false);
            }
            catch (HttpRequestException ex)
            {
                throw new PinnedDownloadException(DownloadProblem.Network, ex.Message, ex);
            }
            catch (TaskCanceledException ex) when (!cancel.IsCancellationRequested)
            {
                throw new PinnedDownloadException(DownloadProblem.Network, "The server didn't answer in time.", ex);
            }
            using (response)
            {
                if (!response.IsSuccessStatusCode)
                    throw new PinnedDownloadException(DownloadProblem.Network, $"The server answered {(int)response.StatusCode}.");
                if (response.Content.Headers.ContentLength is { } announced && announced != size)
                    throw new PinnedDownloadException(DownloadProblem.WrongSize, $"The server offered {announced} bytes, not {size}.");
                long got = 0;
                await using (var file = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
                {
                    Stream body;
                    try
                    {
                        body = await response.Content.ReadAsStreamAsync(cancel).ConfigureAwait(false);
                    }
                    catch (Exception ex) when (ex is HttpRequestException or IOException)
                    {
                        throw new PinnedDownloadException(DownloadProblem.Network, ex.Message, ex);
                    }
                    await using (body)
                    {
                        var buffer = new byte[1 << 16];
                        while (true)
                        {
                            int n;
                            try
                            {
                                n = await body.ReadAsync(buffer, cancel).ConfigureAwait(false);
                            }
                            catch (Exception ex) when (ex is HttpRequestException or IOException || (ex is OperationCanceledException && !cancel.IsCancellationRequested))
                            {
                                throw new PinnedDownloadException(DownloadProblem.Network, ex.Message, ex);
                            }
                            if (n == 0) break;
                            got += n;
                            if (got > size) throw new PinnedDownloadException(DownloadProblem.WrongSize, $"The server sent more than {size} bytes.");
                            hash.AppendData(buffer, 0, n);
                            await file.WriteAsync(buffer.AsMemory(0, n), cancel).ConfigureAwait(false);
                            progress?.Report(got);
                        }
                    }
                }
                if (got != size) throw new PinnedDownloadException(DownloadProblem.WrongSize, $"The server sent {got} bytes, not {size}.");
            }
            if (!string.Equals(Convert.ToHexStringLower(hash.GetHashAndReset()), sha256, StringComparison.OrdinalIgnoreCase))
                throw new PinnedDownloadException(DownloadProblem.WrongContent, "The file isn't the one expected.");
            File.Move(part, destination, overwrite: true);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException)
        {
            TryDelete(part);
            throw new PinnedDownloadException(DownloadProblem.Disk, ex.Message, ex);
        }
        catch
        {
            TryDelete(part);
            throw;
        }
    }

    /// <summary>Whether <paramref name="path"/> is there with the pinned size and SHA-256.</summary>
    public static bool Matches(string path, long size, string sha256, CancellationToken cancel = default)
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
            if (file.Length != size) return false;
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[1 << 16];
            int n;
            while ((n = file.Read(buffer)) > 0)
            {
                cancel.ThrowIfCancellationRequested();
                hash.AppendData(buffer, 0, n);
            }
            return string.Equals(Convert.ToHexStringLower(hash.GetHashAndReset()), sha256, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    internal static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // left for the next try, which writes over it
        }
    }
}

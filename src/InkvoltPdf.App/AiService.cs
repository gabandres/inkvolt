using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>The AI assistant's configuration as saved: where to send, which model, how much it reads at once.</summary>
public sealed record AiConfig(AiEndpoint Endpoint, string Preset, string Model, int ContextTokens)
{
    /// <summary>"Ollama", "LM Studio", or the host for a custom endpoint.</summary>
    public string ServerLabel => Preset switch { "Ollama" => "Ollama", "LMStudio" => "LM Studio", _ => Endpoint.Host };

    public int InputChars => AiText.InputChars(ContextTokens);
}

/// <summary>
/// The bring-your-own AI assistant's settings and connections. Off by default; nothing here talks to any server until
/// the user configures an endpoint and confirms a send. There is no Inkvolt server, default key or telemetry.
/// </summary>
public static class AiService
{
    public static readonly string[] PresetNames = ["Ollama", "LMStudio", "Custom"];

    /// <summary>Dev script only: answers requests instead of the network (see DevScript "aifake").</summary>
    internal static Func<AiEndpoint, HttpMessageHandler>? DevHandler { get; set; }

    public static bool IsEnabled => AppSettings.Current.AiEnabled;

    /// <summary>The base URL a preset stands for (Custom: the saved custom URL).</summary>
    public static string UrlOf(string preset, string customUrl) => preset switch
    {
        "Ollama" => AiEndpoint.OllamaUrl,
        "LMStudio" => AiEndpoint.LmStudioUrl,
        _ => customUrl,
    };

    /// <summary>The saved configuration, or null with the reason when the assistant is off or incomplete.</summary>
    public static AiConfig? Current(out string? problem)
    {
        var s = AppSettings.Current;
        problem = null;
        if (!s.AiEnabled)
        {
            problem = "The AI assistant is off.";
            return null;
        }
        if (!AiEndpoint.TryParse(UrlOf(s.AiPreset, s.AiCustomUrl), out var ep, out var error))
        {
            problem = error;
            return null;
        }
        if (string.IsNullOrWhiteSpace(s.AiModel))
        {
            problem = "Choose a model for the AI assistant.";
            return null;
        }
        return new AiConfig(ep!, s.AiPreset, s.AiModel.Trim(), Math.Clamp(s.AiContextTokens, 1024, 2_000_000));
    }

    public static AiClient CreateClient(AiEndpoint endpoint, string model) =>
        new(endpoint, model, AiKeyStore.Get(endpoint.Key), DevHandler?.Invoke(endpoint));

    public static AiClient CreateClient(AiEndpoint endpoint, string model, string? apiKey) =>
        new(endpoint, model, apiKey, DevHandler?.Invoke(endpoint));

    public static bool SkipsPreview(AiEndpoint ep) => AppSettings.Current.AiNoPreview.Contains(ep.Key, StringComparer.OrdinalIgnoreCase);

    public static bool WarnedAbout(AiEndpoint ep) => ep.Reach != AiReach.Internet || AppSettings.Current.AiCloudWarned.Contains(ep.Key, StringComparer.OrdinalIgnoreCase);
}

/// <summary>
/// API keys for AI endpoints, one per endpoint (a key goes only to the endpoint it was entered for). Kept in
/// ai-keys.dat in the data folder, encrypted with Windows DPAPI for the current user: never in settings.json, never
/// logged, unreadable for other Windows accounts and on other PCs.
/// </summary>
public static class AiKeyStore
{
    private static readonly byte[] Entropy = "InkvoltPdf.AiKeys.v1"u8.ToArray();
    private static string FilePath => Path.Combine(AppPaths.DataDirectory, "ai-keys.dat");

    public static string? Get(string endpointKey) => Load().GetValueOrDefault(endpointKey);

    public static bool Has(string endpointKey) => Get(endpointKey) is { Length: > 0 };

    /// <summary>Saves (or with null, forgets) the key for an endpoint.</summary>
    public static void Set(string endpointKey, string? apiKey)
    {
        var keys = Load();
        if (string.IsNullOrWhiteSpace(apiKey)) keys.Remove(endpointKey);
        else keys[endpointKey] = apiKey.Trim();
        try
        {
            if (keys.Count == 0)
            {
                if (File.Exists(FilePath)) File.Delete(FilePath);
                return;
            }
            var plain = JsonSerializer.SerializeToUtf8Bytes(keys);
            var sealedBytes = ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);
            CryptographicOperations.ZeroMemory(plain);
            Directory.CreateDirectory(AppPaths.DataDirectory);
            AtomicFile.WriteAllBytes(FilePath, sealedBytes);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException)
        {
            Log.Write($"AI keys not saved: {ex.GetType().Name}"); // never the key itself
            throw new InvalidOperationException("The API key couldn't be saved on this PC.", ex);
        }
    }

    private static Dictionary<string, string> Load()
    {
        try
        {
            if (!File.Exists(FilePath)) return new(StringComparer.OrdinalIgnoreCase);
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(FilePath), Entropy, DataProtectionScope.CurrentUser);
            var keys = JsonSerializer.Deserialize<Dictionary<string, string>>(Encoding.UTF8.GetString(plain)) ?? [];
            CryptographicOperations.ZeroMemory(plain);
            return new(keys, StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException or JsonException)
        {
            Log.Write($"AI keys unreadable ({ex.GetType().Name}); enter the key again");
            return new(StringComparer.OrdinalIgnoreCase);
        }
    }
}

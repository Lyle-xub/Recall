using System.Security.Cryptography;
using System.Text;
namespace Rewind;

[System.Runtime.Versioning.SupportedOSPlatform("windows")]
public static class SecretStore
{
    public static string Read(string account)
    {
        var file = Path.Combine(AppPaths.DataRoot, account + ".key");
        if (!File.Exists(file))
            return "";
        return Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(file), null, DataProtectionScope.CurrentUser));
    }
    public static void Save(string account, string secret)
    {
        var file = Path.Combine(AppPaths.DataRoot, account + ".key");
        if (secret.Length == 0)
        {
            if (File.Exists(file))
                File.Delete(file);
            return;
        }
        File.WriteAllBytes(file, ProtectedData.Protect(Encoding.UTF8.GetBytes(secret), null, DataProtectionScope.CurrentUser));
    }
}

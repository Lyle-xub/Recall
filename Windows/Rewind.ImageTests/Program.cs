using Rewind;

var root = Path.Combine(Path.GetTempPath(), "recall-image-test-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    var checks = ImageArchiveTests.Run(root);
    Console.WriteLine($"PASS: {checks} image archive seam checks.");
    var native = VisualVideoArchiveTests.Run(root);
    Console.WriteLine($"PASS: {native} native Media Foundation archive checks.");
}
finally { Directory.Delete(root, true); }

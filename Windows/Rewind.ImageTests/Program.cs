using Rewind;

var output = Environment.GetEnvironmentVariable("RECALL_IMAGE_TEST_OUTPUT");
var retainOutput = !string.IsNullOrWhiteSpace(output);
if (retainOutput && !Path.IsPathFullyQualified(output!))
    throw new ArgumentException("RECALL_IMAGE_TEST_OUTPUT must be an absolute path.");
var root = retainOutput ? output! : Path.Combine(Path.GetTempPath(), "recall-image-test-" + Guid.NewGuid());
if (Directory.Exists(root) && Directory.EnumerateFileSystemEntries(root).Any())
    throw new IOException("The image test output directory must be empty.");
Directory.CreateDirectory(root);
try
{
    var checks = ImageArchiveTests.Run(root);
    Console.WriteLine($"PASS: {checks} image archive seam checks.");
    var native = VisualVideoArchiveTests.Run(root);
    Console.WriteLine($"PASS: {native} native Media Foundation archive checks.");
}
finally
{
    if (retainOutput) Console.WriteLine($"Image test artifacts: {root}");
    else Directory.Delete(root, true);
}

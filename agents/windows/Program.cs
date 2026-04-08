using GUIVisionAgent;
using GUIVisionAgent.Services;

var port = args.Length > 0 && int.TryParse(args[0], out var p) ? p : 8648;

var builder = WebApplication.CreateBuilder();
builder.WebHost.UseUrls($"http://0.0.0.0:{port}");
builder.Logging.SetMinimumLevel(LogLevel.Warning);

var app = builder.Build();

using var windowEnumerator = new WindowEnumerator();
app.MapSystemEndpoints(windowEnumerator);
app.MapAccessibilityEndpoints(windowEnumerator);

Console.WriteLine($"guivision-agent listening on http://0.0.0.0:{port}");
app.Run();

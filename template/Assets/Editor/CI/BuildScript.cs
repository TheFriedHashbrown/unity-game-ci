using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace CI
{
    /// <summary>
    /// Batch-mode build entry point for the GitHub Actions pipeline
    /// (game-ci/unity-builder is pointed at CI.BuildScript.Build).
    ///
    /// Build settings live here rather than in ProjectSettings so CI output is identical
    /// no matter what anyone last toggled in the editor.
    /// </summary>
    public static class BuildScript
    {
        public static void Build()
        {
            var args = ParseArgs();

            try
            {
                var target = ResolveTarget(args);
                var outputPath = ResolveOutputPath(args, target);
                var version = Value(args, "buildVersion", "CIBuildVersion");

                if (!string.IsNullOrEmpty(version))
                {
                    PlayerSettings.bundleVersion = version;
                    Log("version = " + version);
                }

                var commit = Value(args, "CICommit");
                if (!string.IsNullOrEmpty(commit))
                {
                    Log("commit = " + commit);
                }

                // Only override compression when CI explicitly asks; otherwise the
                // project's own WebGL settings (or its build profile) stay in charge.
                var compression = Value(args, "CICompression");
                if (target == BuildTarget.WebGL && !string.IsNullOrEmpty(compression))
                {
                    ConfigureWebGL(compression);
                }

                var scenes = EnabledScenes();
                if (scenes.Length == 0)
                {
                    Fail("No enabled scenes in Build Settings - nothing to build.");
                    return;
                }

                var options = new BuildPlayerOptions
                {
                    scenes = scenes,
                    target = target,
                    targetGroup = BuildPipeline.GetBuildTargetGroup(target),
                    locationPathName = outputPath,
                    options = args.ContainsKey("CIDevelopmentBuild")
                        ? BuildOptions.Development
                        : BuildOptions.None,
                };

                Log("target = " + target);
                Log("output = " + outputPath);
                Log("scenes = " + scenes.Length);

                var report = BuildPipeline.BuildPlayer(options);
                var summary = report.summary;

                var elapsed = summary.totalTime;
                Log(string.Format(
                    "result = {0}, size = {1} MB, duration = {2:D2}:{3:D2}:{4:D2}, errors = {5}, warnings = {6}",
                    summary.result, summary.totalSize / (1024 * 1024),
                    elapsed.Hours, elapsed.Minutes, elapsed.Seconds,
                    summary.totalErrors, summary.totalWarnings));

                if (summary.result != BuildResult.Succeeded)
                {
                    foreach (var step in report.steps)
                    {
                        foreach (var message in step.messages
                                     .Where(m => m.type == LogType.Error || m.type == LogType.Exception))
                        {
                            Debug.LogError("[CI] " + step.name + ": " + message.content);
                        }
                    }

                    Fail("Build finished with result " + summary.result + ".");
                    return;
                }

                EditorApplication.Exit(0);
            }
            catch (Exception e)
            {
                Fail("Unhandled exception: " + e);
            }
        }

        private static void ConfigureWebGL(string compression)
        {
            switch (compression.ToLowerInvariant())
            {
                case "gzip":
                    PlayerSettings.WebGL.compressionFormat = WebGLCompressionFormat.Gzip;
                    break;
                case "disabled":
                case "none":
                    PlayerSettings.WebGL.compressionFormat = WebGLCompressionFormat.Disabled;
                    break;
                default:
                    PlayerSettings.WebGL.compressionFormat = WebGLCompressionFormat.Brotli;
                    break;
            }

            // ci/deploy-r2.sh sets Content-Encoding on every object, so the JS decompression
            // fallback is dead weight: it inflates the loader and hides genuine header
            // misconfiguration behind a slow, silent code path.
            PlayerSettings.WebGL.decompressionFallback = false;
            PlayerSettings.WebGL.dataCaching = true;
            PlayerSettings.WebGL.exceptionSupport = WebGLExceptionSupport.ExplicitlyThrownExceptionsOnly;

            Log("WebGL compression = " + PlayerSettings.WebGL.compressionFormat + ", fallback = off");
        }

        private static string[] EnabledScenes()
        {
            return EditorBuildSettings.scenes
                .Where(s => s.enabled && File.Exists(s.path))
                .Select(s => s.path)
                .ToArray();
        }

        private static BuildTarget ResolveTarget(IReadOnlyDictionary<string, string> args)
        {
            var raw = Value(args, "buildTarget");
            if (string.IsNullOrEmpty(raw))
            {
                return EditorUserBuildSettings.activeBuildTarget;
            }

            BuildTarget parsed;
            if (Enum.TryParse(raw, true, out parsed))
            {
                return parsed;
            }

            throw new ArgumentException("Unknown build target '" + raw + "'.");
        }

        private static string ResolveOutputPath(IReadOnlyDictionary<string, string> args, BuildTarget target)
        {
            // game-ci/unity-builder passes -customBuildPath; the override is for local runs.
            var custom = Value(args, "customBuildPath", "CIOutputPath");
            if (!string.IsNullOrEmpty(custom))
            {
                return custom;
            }

            var name = Value(args, "customBuildName") ?? PlayerSettings.productName;
            var dir = Path.Combine("build", target.ToString(), name);

            // WebGL wants a folder; the standalone players want an executable path.
            switch (target)
            {
                case BuildTarget.WebGL:
                    return dir;
                case BuildTarget.StandaloneWindows:
                case BuildTarget.StandaloneWindows64:
                    return Path.Combine(dir, name + ".exe");
                case BuildTarget.StandaloneOSX:
                    return Path.Combine(dir, name + ".app");
                case BuildTarget.Android:
                    return Path.Combine(dir, name + ".apk");
                default:
                    return Path.Combine(dir, name);
            }
        }

        private static Dictionary<string, string> ParseArgs()
        {
            var args = Environment.GetCommandLineArgs();
            var parsed = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

            for (var i = 0; i < args.Length; i++)
            {
                if (!args[i].StartsWith("-", StringComparison.Ordinal))
                {
                    continue;
                }

                var key = args[i].TrimStart('-');
                var hasValue = i + 1 < args.Length && !args[i + 1].StartsWith("-", StringComparison.Ordinal);
                parsed[key] = hasValue ? args[i + 1] : string.Empty;
            }

            return parsed;
        }

        private static string Value(IReadOnlyDictionary<string, string> args, params string[] keys)
        {
            foreach (var key in keys)
            {
                string value;
                if (args.TryGetValue(key, out value) && !string.IsNullOrEmpty(value))
                {
                    return value;
                }
            }

            return null;
        }

        private static void Log(string message)
        {
            Debug.Log("[CI] " + message);
        }

        private static void Fail(string message)
        {
            Debug.LogError("[CI] " + message);
            EditorApplication.Exit(1);
        }
    }
}

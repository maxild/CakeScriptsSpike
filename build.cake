///////////////////////////////////////////////////////////////////////////////
// SCRIPTS
///////////////////////////////////////////////////////////////////////////////
// PackageIds are case insensitive in NuGet so to prevent ambiguity they are always
// installed in the global packages folder with lowercase names.
#load "./tools/maxfire.cakescripts/0.1.116/content/all.cake"

///////////////////////////////////////////////////////////////////////////////
// GLOBAL VARIABLES
///////////////////////////////////////////////////////////////////////////////

var parameters = CakeScripts.GetParameters(
    Context,            // ICakeContext
    BuildSystem,        // BuildSystem alias
    new BuildSettings() // My personal overrides
    {
        MainRepositoryOwner = "maxild",
        RepositoryName = "CakeScriptsSpike",
    }
    );

///////////////////////////////////////////////////////////////////////////////
// SETUP / TEARDOWN
///////////////////////////////////////////////////////////////////////////////

Setup(context =>
{
    Information("Building version {0} of {1} ({2}, {3}) using version {4} of Cake and '{5}' of GitVersion. (IsTagPush: {6})",
        parameters.VersionInfo.SemVer,
        parameters.ProjectName,
        parameters.Configuration,
        parameters.Target,
        parameters.VersionInfo.CakeVersion,
        parameters.VersionInfo.GitVersionVersion,
        parameters.IsTagPush);
});


Task("Default")
    .Does(() =>
{
    Information("Hello world");
});

///////////////////////////////////////////////////////////////////////////////
// EXECUTION
///////////////////////////////////////////////////////////////////////////////

RunTarget(parameters.Target);

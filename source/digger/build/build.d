module digger.build.build;

/// Represents one build.
final class BuildContext
{
	/// Current build environment.
	package struct Environment
	{
		/// Configuration for software dependencies
		struct Deps
		{
			string dmcDir;   /// Where dmc.zip is unpacked.
			string vsDir;    /// Where Visual Studio is installed
			string sdkDir;   /// Where the Windows SDK is installed
			string hostDC;   /// Host D compiler (for DDMD bootstrapping)
		}
		Deps deps; /// ditto

		/// Calculated local environment, incl. dependencies
		string[string] vars;
	}


}

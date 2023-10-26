using System;
using System.Reflection;

namespace TermBuddy
{
	class Program
	{
		static int32 Main(String[] args)
		{
			TBApp app = new .();
			app.ParseCommandLine(args);
			app.Init();
			app.Run();
			app.Shutdown();
			delete app;

			return 0;
		}
	}
}

using Beefy.widgets;
using Beefy.gfx;

namespace TermBuddy
{
	class StatusBar : Widget
	{
		public override void Draw(Graphics g)
		{
			base.Draw(g);

			g.SetFont(gApp.mFont);

			uint32 bkgColor = 0xFF404040;
			using (g.PushColor(bkgColor))
				g.FillRect(0, 0, mWidth, mHeight);

			if (gApp.mBoard.mContent.Paused)
				g.DrawString("Paused...", 8, 2);
			else if (gApp.mProcess != null)
				g.DrawString("Executing...", 8, 2);
			else if (gApp.mInData.Length > 0)
				g.DrawString(scope $"Sending {(gApp.mInData.Length + 1023)/1024}k...", 8, 2);
			else if (gApp.mViewMode == .Monitor)
				g.DrawString("Monitoring COM3", 8, 2);
			else if (gApp.mHadError)
			{
				using (g.PushColor(0xFFFF0000))
					g.DrawString("FAILED", 8, 2);
			}

			var lineAndColumn = gApp.mBoard.mDocEdit.mEditWidgetContent.CursorLineAndColumn;
			g.DrawString(StackStringFormat!("Ln {0}", lineAndColumn.mLine + 1), mWidth - 160, 2);
			g.DrawString(StackStringFormat!("Col {0}", lineAndColumn.mColumn + 1), mWidth - 80, 2);
		}
	}
}

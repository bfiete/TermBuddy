using Beefy.widgets;
using Beefy.gfx;
using Beefy.theme.dark;
using System;
using System.IO;
using Beefy.utils;
using System.Threading;
using System.Collections;
using System.Diagnostics;

namespace TermBuddy
{
	class TermEditWidgetContent : DarkEditWidgetContent
	{
		struct QueuedTextEntry
		{
		    public String mString;
		    public float mX;
		    public float mY;
		    public uint16 mTypeIdAndFlags;

			public void Dispose()
			{
				delete mString;
			}
		}

		List<QueuedTextEntry> mQueuedText = new List<QueuedTextEntry>() ~ delete _;
		public bool mInserting;
		public int mContentCursorPos;
		public int32 mColor = 7;
		public int32? mPausePrevCursor;
		public bool Paused
		{
			get => mPausePrevCursor != null;
			set
			{
				if ((!value) && (mPausePrevCursor != null))
				{
					CurSelection = null;
					CursorTextPos = mPausePrevCursor.Value;
					mPausePrevCursor = null;
				}
			}
		}

		public uint32[] mAnsiColors = new .(
			0xFF000000, 0xFFCC0000, 0xFF00CC00, 0xFFC19C00, 0xFF0000CC, 0xFFAA00CC, 0xFF00CCCC, 0xFFCCCCCC,
			0xFF555555, 0xFFFF5555, 0xFF55FF55, 0xFFFFFF55, 0xFF5555FF, 0xFFFF55FF, 0xFF55FFFF, 0xFFFFFFFF) ~ delete _;

		public this()
		{
			
		}

		public override void InsertAtCursor(String theString, InsertFlags insertFlags = .None)
		{
			if (mInserting)
			{
				if (theString.Length == 0)
					return;

				if (theString.Contains('\b'))
				{
					int backPos = theString.IndexOf('\b');
					String substr = scope .();

					substr.Set(theString.Substring(0, backPos));
					InsertAtCursor(substr, insertFlags);

					Backspace();

					substr.Set(theString.Substring(backPos + 1));
					InsertAtCursor(substr, insertFlags);
				}

				int prevPos = CursorTextPos;
				base.InsertAtCursor(theString, insertFlags);
				for (int i = prevPos; i <= CursorTextPos; i++)
					mData.mText[i].mDisplayTypeId = (.)mColor; 

				mContentCursorPos = CursorTextPos;
				return;
			}

			if (Paused)
				Paused = false;
		}

		public override void KeyChar(char32 c)
		{
			base.KeyChar(c);

			using (gApp.mMonitor.Enter())
			{
				gApp.mInData.Append(c);
			}
		}

		public override bool CheckReadOnly()
		{
			if (!mInserting)
				return true;
			return base.CheckReadOnly();
		}

		public override void PhysCursorMoved(CursorMoveKind moveKind)
		{
			base.PhysCursorMoved(moveKind);

			if ((!mInserting) && (!Paused))
				mPausePrevCursor = mData.mTextLength;
		}

		public override float DrawText(Graphics g, String str, float x, float y, uint16 typeIdAndFlags)
		{
			//uint32 bgColor = mAnsiColors[(typeIdAndFlags >> 4) & 0xF];

			QueuedTextEntry queuedTextEntry;
			queuedTextEntry.mString = new String(str);
			queuedTextEntry.mX = x;
			queuedTextEntry.mY = y;
			queuedTextEntry.mTypeIdAndFlags = typeIdAndFlags;
			mQueuedText.Add(queuedTextEntry);

			float len = DoDrawText(null, str, x, y);

			return len;

			/*using (g.PushColor(mTextColors[typeIdAndFlags & 0xFF]))
				return DoDrawText(g, str, x, y);*/
		}

		public override void Draw(Graphics g)
		{
			base.Draw(g);

			for (var queuedTextEntry in mQueuedText)
			{
				uint32 fgColor = mAnsiColors[queuedTextEntry.mTypeIdAndFlags & 0xF];
			    using (g.PushColor(fgColor))
			    {
			        DoDrawText(g, queuedTextEntry.mString, queuedTextEntry.mX, queuedTextEntry.mY);
			    }
				queuedTextEntry.Dispose();
			}
			mQueuedText.Clear();
		}

		public override void MouseDown(float x, float y, int32 btn, int32 btnCount)
		{
			int32 startingCursorPos = (.)CursorTextPos;
			if (btn != 0)
			{
				if (btn == 1)
				{
					Menu menu = new Menu();
					Menu menuItem;

					menuItem = menu.AddItem("Clear");
					menuItem.mOnMenuItemSelected.Add(new (menu) =>
						{
							gApp.ClearOutput();
						});
					MenuWidget menuWidget = DarkTheme.sDarkTheme.CreateMenuWidget(menu);
					menuWidget.Init(this, x, y);
				}

				return;
			}

			base.MouseDown(x, y, btn, btnCount);
			if ((btn == 0) && (CursorTextPos != startingCursorPos))
			{
				if (!Paused)
					mPausePrevCursor = startingCursorPos;
			}
		}

		public override void KeyDown(KeyCode keyCode, bool isRepeat)
		{
			if (Paused)
			{
				if (keyCode == .Escape)
					Paused = false;
			}
			else
			{
				/*switch (keyCode)
				{
				case .Up:
					gApp.mInData.Append("\x1B[A");
					return;
				case .Down:
					gApp.mInData.Append("\x1B[B");
					return;
				case .Left:
					gApp.mInData.Append("\x1B[D");
					return;
				case .Right:
					gApp.mInData.Append("\x1B[C");
					return;
				case .PageUp:
					gApp.mInData.Append("\x1B[S");
					return;
				case .PageDown:
					gApp.mInData.Append("\x1B[T");
					return;
				default:
				}*/
			}

			base.KeyDown(keyCode, isRepeat);
		}
	}

	class Board : Widget
	{
		public struct Match
		{
			public int32 mFilterIdx;
			public int32 mTextIdx;
		}

		public TermEditWidgetContent mContent;
		public DarkEditWidget mDocEdit;
		public StatusBar mStatusBar;
		public String mNewContent ~ delete _;
		public List<DarkButton> mButtons = new .() ~ delete _;

		public this()
		{

			mStatusBar = new StatusBar();
			AddWidget(mStatusBar);

			mContent = new .();

			mDocEdit = new DarkEditWidget(mContent);
			var ewc = (DarkEditWidgetContent)mDocEdit.mEditWidgetContent;
			ewc.mIsMultiline = true;
			ewc.mFont = gApp.mFont;
			ewc.mWordWrap = false;
			mDocEdit.InitScrollbars(true, true);
			AddWidget(mDocEdit);

			void AddButton(String label, Action act)
			{
				DarkButton button = new DarkButton();
				button.Label = label;
				button.mOnMouseClick.Add(new (mouseArgs) =>
					{
						act();
						mDocEdit.SetFocus();
					} ~ delete act);
				button.mAutoFocus = false;
				AddWidget(button);
				mButtons.Add(button);
			}

			AddButton("Workspace", new => gApp.DoWorkspace);
			AddButton("Build", new => gApp.DoBuild);
			AddButton("Flash", new => gApp.DoFlash);
			AddButton("Monitor", new => gApp.DoMonitor);
			AddButton("Build+Monitor", new => gApp.DoBuildAndMonitor);
			AddButton("FPGA Program", new => gApp.DoProgram);
			AddButton("FPGA Reprogram", new => gApp.DoReprogram);
			AddButton("Read", new => gApp.DoReadProgram);
			AddButton("Verify", new => gApp.DoVerify);
			AddButton("Reset", new => gApp.DoReset);
			AddButton("Idle", new => gApp.DoIdle);
			AddButton("Res Write", new => gApp.DoResWrite);
			AddButton("Res Rewrite", new => gApp.DoResRewrite);
		}
	
		public override void Draw(Graphics g)
		{
			base.Draw(g);

			//using (g.PushColor(0xFFE02040))
				//g.FillRect(0, 0, mWidth, mHeight);

			g.DrawBox(DarkTheme.sDarkTheme.GetImage(.Bkg), 0, 0, mWidth, mHeight);
		}

		public override void DrawAll(Graphics g)
		{
			base.DrawAll(g);

			if (gApp.mBoard.mContent.Paused)
			{
				using (g.PushColor(0x12FFFFFF))
					g.FillRect(0, 0, mWidth, mHeight);
			}

			/*g.SetFont(gApp.mFont);
			g.DrawString(scope String()..AppendF("FPS: {0}", gApp.mLastFPS), 0, 0);*/
		}

		void ResizeComponents()
		{
			float statusBarHeight = 20;
			float btnHeight = 24;

			float btnWidth = 120;

			int colSize = (.)(mWidth / btnWidth);
			int numRows = (mButtons.Count + colSize - 1) / colSize;

			//btnWidth = (mWidth - 2) / colSize;

			mDocEdit.Resize(0, 0, mWidth, mHeight - btnHeight * numRows - statusBarHeight);

			for (int i < mButtons.Count)
			{
				mButtons[i].Resize(2 + (i % colSize) * btnWidth, mHeight - statusBarHeight - btnHeight*numRows + (i / colSize)*(btnHeight), btnWidth, btnHeight);
			}

			mStatusBar.Resize(0, mHeight - statusBarHeight, mWidth, statusBarHeight);
		}

		public override void Resize(float x, float y, float width, float height)
		{
			base.Resize(x, y, width, height);
			ResizeComponents();
		}

		public override void Update()
		{
			base.Update();
		}
	}
}

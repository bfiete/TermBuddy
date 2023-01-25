using Beefy;
using Beefy.widgets;
using Beefy.theme.dark;
using Beefy.theme;
using Beefy.gfx;
using System;
using Beefy.utils;
using System.IO;
using System.Diagnostics;
using System.Threading;
using System.Collections;

namespace TermBuddy
{
	class TBApp : BFApp
	{
		public enum ViewMode
		{
			None,
			Process,
			Monitor
		}

		[CRepr]
		struct DCB
		{
		    public uint32 DCBlength = sizeof(DCB);      /* sizeof(DCB)                     */
		    public uint32 BaudRate;       /* Baudrate at which running       */
		    //uint32 fBinary: 1;     /* Binary Mode (skip EOF check)    */
		    //uint32 fParity: 1;     /* Enable parity checking          */
		    //uint32 fOutxCtsFlow:1; /* CTS handshaking on output       */
		    //uint32 fOutxDsrFlow:1; /* DSR handshaking on output       */
		    //uint32 fDtrControl:2;  /* DTR Flow control                */
		    //uint32 fDsrSensitivity:1; /* DSR Sensitivity              */
		    //uint32 fTXContinueOnXoff: 1; /* Continue TX when Xoff sent */
		    //uint32 fOutX: 1;       /* Enable output X-ON/X-OFF        */
		    //uint32 fInX: 1;        /* Enable input X-ON/X-OFF         */
		    //uint32 fErrorChar: 1;  /* Enable Err Replacement          */
		    //uint32 fNull: 1;       /* Enable Null stripping           */
		    //uint32 fRtsControl:2;  /* Rts Flow control                */
		    //uint32 fAbortOnError:1; /* Abort all reads and writes on Error */
		    //uint32 fDummy2:17;     /* Reserved                        */
			[Bitfield(.Public, .Bits(1), "fBinary")]
			[Bitfield(.Public, .Bits(1), "fParity")]
			[Bitfield(.Public, .Bits(1), "fOutxCtsFlow")]
			[Bitfield(.Public, .Bits(1), "fOutxDsrFlow")]
			[Bitfield(.Public, .Bits(2), "fDtrControl")]
			[Bitfield(.Public, .Bits(1), "fDsrSensitivity")]
			[Bitfield(.Public, .Bits(1), "fTXContinueOnXoff")]
			[Bitfield(.Public, .Bits(1), "fOutX")]
			[Bitfield(.Public, .Bits(1), "fInX")]
			[Bitfield(.Public, .Bits(1), "fErrorChar")]
			[Bitfield(.Public, .Bits(1), "fNull")]
			[Bitfield(.Public, .Bits(1), "fRtsControl")]
			[Bitfield(.Public, .Bits(1), "fAbortOnError")]
			public uint32 mFlags;
		    public uint16 wReserved;       /* Not currently used              */
		    public uint16 XonLim;          /* Transmit X-ON threshold         */
		    public uint16 XoffLim;         /* Transmit X-OFF threshold        */
		    public uint8 ByteSize;        /* Number of bits/byte, 4-8        */
		    public uint8 Parity;          /* 0-4=None,Odd,Even,Mark,Space    */
		    public uint8 StopBits;        /* 0,1,2 = 1, 1.5, 2               */
		    public char8 XonChar;         /* Tx and Rx X-ON character        */
		    public char8 XoffChar;        /* Tx and Rx X-OFF character       */
		    public char8 ErrorChar;       /* Error replacement char          */
		    public char8 EofChar;         /* End of Input character          */
		    public char8 EvtChar;         /* Received Event character        */
		    public uint16 wReserved1;      /* Fill for now.                   */
		}

		[CRepr]
		struct COMMTIMEOUTS
		{
			public uint32 ReadIntervalTimeout;
			public uint32 ReadTotalTimeoutMultiplier;
			public uint32 ReadTotalTimeoutConstant;
			public uint32 WriteTotalTimeoutMultiplier;
			public uint32 WriteTotalTimeoutConstant;
		}

		public class PendingInData
		{
			public String mData ~ delete _;
			public int mDelay;
		}

		public WidgetWindow mMainWindow;
		public Board mBoard;
		public Font mFont ~ delete _;
		public SpawnedProcess mProcess ~ delete _;
		public Monitor mMonitor = new .() ~ delete _;
		public String mInData = new .() ~ delete _;
		public String mOutputData = new .() ~ delete _;
		public Thread mOutputThread ~ delete _;
		public Thread mErrorThread ~ delete _;
		public Thread mInputThread ~ delete _;
		public Thread mComReadThread ~ delete _;
		public Thread mComWriteThread ~ delete _;
		public bool mPendingMonitor;
		public ViewMode mViewMode;
		public Windows.FileHandle mComHandle;
		public bool mHadError;
		public String mProgramFilePath = new .() ~ delete _;
		public List<PendingInData> mPendingInData = new .() ~ delete _;
		public List<uint8> mVerifyData ~ delete _;
		public List<uint8> mReadProgramData ~ delete _;
		public String mOutputLineData = new .() ~ delete _;

		public this()
		{
			gApp = this;
		}

		[CLink, CallingConvention(.Stdcall)]
		public static extern uint32 SetCommBreak(Windows.FileHandle handle);
		[CLink, CallingConvention(.Stdcall)]
		public static extern uint32 ClearCommBreak(Windows.FileHandle handle);
		[CLink, CallingConvention(.Stdcall)]
		public static extern uint32 EscapeCommFunction(Windows.FileHandle handle, uint32 func);

		[CLink, CallingConvention(.Stdcall)]
		public static extern uint32 GetCommState(Windows.FileHandle handle, out DCB dcb);
		[CLink, CallingConvention(.Stdcall)]
		public static extern uint32 SetCommState(Windows.FileHandle handle, ref DCB dcb);
		[CLink, CallingConvention(.Stdcall)]
		public static extern uint32 SetCommTimeouts(Windows.FileHandle handle, ref COMMTIMEOUTS timeouts);

		void OpenCom()
		{
			mComHandle = Windows.CreateFileA("\\\\.\\COM3", Windows.GENERIC_READ | Windows.GENERIC_WRITE, 0, null, .Open, 0x00000080, default);
			if (mComHandle.IsInvalid)
				return;

			DCB dcb = .();
			GetCommState(mComHandle, out dcb);

			dcb = default;
			dcb.DCBlength = 28;
			dcb.BaudRate = 115200;
			dcb.mFlags = 1;
			dcb.XoffLim = 16384;
			dcb.ByteSize = 8;
			dcb.StopBits = 0;
			dcb.Parity = 0;
			dcb.XonChar = 0;
			dcb.XoffChar = 0;
			SetCommState(mComHandle, ref dcb);

			COMMTIMEOUTS timeouts = default;
			timeouts.ReadIntervalTimeout = 0xFFFFFFFF;
			timeouts.ReadTotalTimeoutMultiplier = 0xFFFFFFFF;
			timeouts.ReadTotalTimeoutConstant = 1;
			timeouts.WriteTotalTimeoutMultiplier = 1;
			timeouts.WriteTotalTimeoutConstant = 1;
			SetCommTimeouts(mComHandle, ref timeouts);
		}

		void CloseCom()
		{
			if (mComHandle.IsInvalid)
				return;

			Windows.CloseHandle(mComHandle);

			mComHandle = default;
		}

		void ReadOutputThread()
		{
			UnbufferedFileStream fileStream = scope UnbufferedFileStream();
			if (mProcess.AttachStandardOutput(fileStream) case .Err)
				return;

			ReadLoop: while (true)
			{
				uint8[256] data;
				switch (fileStream.TryRead(.(&data, 256), -1))
				{
				case .Ok(int len):
					if (len == 0)
						break ReadLoop;
					using (mMonitor.Enter())
					{
						if (mViewMode == .Process)
							mOutputData.Append(StringView((.)&data, len));
					}
				default:
					break ReadLoop;
				}
			}
		}

		void ReadErrorThread()
		{
			UnbufferedFileStream fileStream = scope UnbufferedFileStream();
			if (mProcess.AttachStandardError(fileStream) case .Err)
				return;

			ReadLoop: while (true)
			{
				uint8[256] data;
				switch (fileStream.TryRead(.(&data, 256), -1))
				{
				case .Ok(int len):
					if (len == 0)
						break ReadLoop;
					using (mMonitor.Enter())
					{
						if (mViewMode == .Process)
							mOutputData.Append(StringView((.)&data, len));
					}
				default:
					break ReadLoop;
				}
			}
		}

		void WriteInputThread()
		{
			UnbufferedFileStream fileStream = scope UnbufferedFileStream();
			if (mProcess.AttachStandardInput(fileStream) case .Err)
				return;

			ReadLoop: while (true)
			{
				if ((mInData.IsEmpty) || (mViewMode != .Process))
				{
					using (mMonitor.Enter())
					{
						if (gApp.mProcess == null)
							break ReadLoop;
					}
					Thread.Sleep(20);
					continue;
				}

				using (mMonitor.Enter())
				{
					switch (fileStream.TryWrite(.((.)mInData.Ptr, mInData.Length)))
					{
					case .Ok(int len):
						mInData.Remove(0, len);
					default:
						break ReadLoop;
					}
				}
				fileStream.Flush();
			}
		}

		void Spawn(ProcessStartInfo psi)
		{
			mProcess = new SpawnedProcess();
			mProcess.Start(psi);

			if (psi.RedirectStandardOutput)
			{
				mOutputThread = new .(new => ReadOutputThread);
				mOutputThread.Start(false);
			}

			if (psi.RedirectStandardError)
			{
				mErrorThread = new .(new => ReadErrorThread);
				mErrorThread.Start(false);
			}

			if (psi.RedirectStandardInput)
			{
				mInputThread = new .(new => WriteInputThread);
				mInputThread.Start(false);
			}
		}

		void KillProcess()
		{
			using (mMonitor.Enter())
				DeleteAndNullify!(mProcess);

			mInputThread?.Join();
			DeleteAndNullify!(mInputThread);
			mOutputThread?.Join();
			DeleteAndNullify!(mOutputThread);
			mErrorThread?.Join();
			DeleteAndNullify!(mErrorThread);
		}

		public void ClearOutput()
		{
			mBoard.mContent.Paused = false;
			mBoard.mContent.ClearText();
			mBoard.mContent.mContentCursorPos = 0;
			mBoard.mContent.CursorTextPos = 0;
			mOutputData.Clear();
		}

		public void ResetConsole()
		{
			ClearOutput();
			mBoard.mContent.mColor = 7;
			mInData.Clear();
			mPendingInData.ClearAndDeleteItems();
			mOutputLineData.Clear();
		}

		void SpawnIDF(String cmds)
		{
			CloseCom();

			mHadError = false;
			mViewMode = .Process;
			ResetConsole();

			mPendingMonitor = false;

			if (mProcess != null)
				KillProcess();

			ProcessStartInfo psi = scope .();
			psi.RedirectStandardInput = true;
			psi.RedirectStandardOutput = true;
			psi.RedirectStandardError = true;
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			psi.SetFileName("cmd.exe");
			//psi.SetArguments(@"/C C:\Espressif\frameworks\esp-idf-v4.4.2\tools\idf.py");

			mInData.Append("\"C:\\Espressif\\idf_cmd_init.bat\" esp-idf-e91d384503485fbb54f6ce3d11e841fe\n");

			if (cmds != null)
			{
				mInData.Append(cmds);
				mInData.Append("\nexit %ErrorLevel%\n");
			}

			Spawn(psi);
		}

		public override void Init()
		{
			base.Init();

			//BeefPerf.Init("127.0.0.1", "TermBuddy");

			DarkTheme darkTheme = new DarkTheme();
			darkTheme.Init();
			ThemeFactory.mDefault = darkTheme;

			BFWindow.Flags windowFlags = BFWindow.Flags.Border | //BFWindow.Flags.SysMenu | //| BFWindow.Flags.CaptureMediaKeys |
			    BFWindow.Flags.Caption | BFWindow.Flags.Minimize | BFWindow.Flags.QuitOnClose | BFWindowBase.Flags.Resizable |
			    BFWindow.Flags.SysMenu;

			mFont = new Font();
			float fontSize = 12;
			mFont.Load(scope String(BFApp.sApp.mInstallDir, "fonts/SourceCodePro-Regular.ttf"), fontSize);
			mFont.AddAlternate("Segoe UI Symbol", fontSize);
			mFont.AddAlternate("Segoe UI Historic", fontSize);
			mFont.AddAlternate("Segoe UI Emoji", fontSize);

			mBoard = new Board();
			//mBoard.Load(dialog.FileNames[0]);
			mMainWindow = new WidgetWindow(null, "TermBuddy", 32, 32, 1024, 768, windowFlags, mBoard);
			//mMainWindow.mWindowKeyDownDelegate.Add(new => SysKeyDown);
			mMainWindow.SetMinimumSize(480, 360);
			mMainWindow.mIsMainWindow = true;

		}

		public override void Shutdown()
		{
			base.Shutdown();
			KillProcess();
		}

		public void Fail(String str, params Object[] paramVals)
		{
			var errStr = scope String();
			errStr.AppendF(str, paramVals);
			Fail(errStr);
		}

		public void DoBuild()
		{
			SpawnIDF("idf.py build");
		}

		public void DoFlash()
		{
			SpawnIDF("idf.py -p COM3 flash");
		}

		public void DoMonitor()
		{
			mViewMode = .Monitor;
			ResetConsole();

			OpenCom();
		}

		public void DoBuildAndMonitor()
		{
			SpawnIDF("idf.py -p COM3 build flash");
			mPendingMonitor = true;
		}

		public bool GetProgramPath()
		{
			if (mViewMode != .Monitor)
				DoMonitor();

			var dialog = scope OpenFileDialog();
			dialog.SetFilter("All files (*.*)|*.*");
			dialog.InitialDirectory = mInstallDir;
			dialog.Title = "Open Program";
			let result = dialog.ShowDialog();
			if ((result case .Err) || (dialog.FileNames.Count == 0))
			{
				return false;
			}

			mProgramFilePath.Set(dialog.FileNames[0]);
			return true;
		}

		public void DoProgram()
		{
			if (!GetProgramPath())
				return;
			if (mProgramFilePath.IsEmpty)
				return;
			DoReprogram();
		}

		public void DoReprogram()
		{
			/*{
				mInData.AppendF($":PROGRAM 6\n");
				mInData.Append("ABCDEF");
				return;
			}*/

			if (mProgramFilePath.IsEmpty)
			{
				DoProgram();
				return;
			}

			List<uint8> data = scope .();
			if (File.ReadAll(mProgramFilePath, data) case .Err)
			{
				Fail(scope $"Failed to read '{mProgramFilePath}'");
				return;
			}

			int32 hash = 0;
			for (int i < data.Count)
				Hash(data[i], ref hash);

			mInData.AppendF($":PROGRAM {data.Count} {hash}\n");

			PendingInData pendingInData = new .();
			pendingInData.mData = new String();
			pendingInData.mDelay = 40;
			for (int i < data.Count)
				pendingInData.mData.AppendF($"{data[i]:X2}");

			//pendingInData.mData.RemoveFromEnd(3);

			mPendingInData.Add(pendingInData);

			//mInData.Append(StringView((.)data.Ptr, data.Count));
		}

		public void DoReadProgram()
		{
			DeleteAndNullify!(mReadProgramData);
			mReadProgramData = new .();

			mInData.Append(":READ\n");
		}

		public void DoVerify()
		{
			if (mProgramFilePath.IsEmpty)
				GetProgramPath();
			if (mProgramFilePath.IsEmpty)
				return;

			DeleteAndNullify!(mReadProgramData);
			mReadProgramData = new .();

			DeleteAndNullify!(mVerifyData);
			mVerifyData = new .();
			if (File.ReadAll(mProgramFilePath, mVerifyData) case .Err)
			{
				Fail($"Failed to read '{mProgramFilePath}'");
				return;
			}

			mInData.Append(":READ\n");
		}

		public void DoReset()
		{
			ResetConsole();

			//EscapeCommFunction(mComHandle, 5/*SETDTR*/);
			EscapeCommFunction(mComHandle, 3/*SETRTS*/);
			Thread.Sleep(20);
			//EscapeCommFunction(mComHandle, 6/*CLRDTR*/);
			EscapeCommFunction(mComHandle, 4/*CLRRTS*/);
		}

		public void DoIdle()
		{
			ResetConsole();
			CloseCom();
			mViewMode = .None;
		}

		public void DoShell()
		{
			SpawnIDF(null);
		}

		int HexToInt(char8 c)
		{
		    if ((c >= '0') && (c <= '9'))
		        return c - '0';
		    if ((c >= 'A') && (c <= 'F'))
		        return c - 'A' + 10;
		    if ((c >= 'a') && (c <= 'f'))
		        return c - 'a' + 10;
		    return -1;
		}

		void Hash(uint8 val, ref int32 hash)
		{
			hash = ((hash ^ (int32)val) << 5) &- hash;
		}

		public override void Update(bool batchStart)
		{
			base.Update(batchStart);

			if (!mPendingInData.IsEmpty)
			{
				var pendingInData = mPendingInData.Front;
				if (--pendingInData.mDelay <= 0)
				{
					mInData.Append(pendingInData.mData);
					delete pendingInData;
					mPendingInData.PopFront();
				}
			}

			if (!mComHandle.IsInvalid)
			{
				uint8[1024] data = ?;
				int result = Windows.ReadFile(mComHandle, &data, data.Count, var numBytesRead, null);
				if (result > 0)
				{
					if (mViewMode == .Monitor)
					{
						using (mMonitor.Enter())
						{
							mOutputData.Append(StringView((.)&data, numBytesRead));
						}
						mOutputLineData.Append(StringView((.)&data, numBytesRead));
					}
				}

				if ((!mInData.IsEmpty) && (mIsUpdateBatchStart))
				{
					result = Windows.WriteFile(mComHandle, (.)mInData.Ptr, (.)Math.Min(mInData.Length, 128), var numBytesWritten, null);
					if (result > 0)
						mInData.Remove(0, numBytesWritten);
				}
			}

			while (true)
			{
				int crPos = mOutputLineData.IndexOf('\n');
				if (crPos == -1)
					break;

				StringView line = mOutputLineData.Substring(0, crPos);
				if (line.EndsWith('\r'))
					line.RemoveFromEnd(1);

				if (line.StartsWith(":READ SIZE "))
				{
					//int 
				}
				else if (line.StartsWith(":READ DATA "))
				{
					int pos = ":READ DATA ".Length;
					while (pos < line.Length)
					{
						int val = (HexToInt(line[pos]) * 0x10) | HexToInt(line[pos+1]);
						if ((val < 0) || (val > 0xFF))
						{
							Fail("Reading failed");
							break;
						}
						mReadProgramData.Add((uint8)val);
						pos += 2;
					}
				}
				else if (line.StartsWith(":READ DONE"))
				{
					if (mVerifyData != null)
					{
						bool matched = true;
						if (mVerifyData.Count != mReadProgramData.Count)
							matched = false;
						else
						{
							for (int i < mVerifyData.Count)
								if (mVerifyData[i] != mReadProgramData[i])
									matched = false;
						}

						if (!matched)
							Fail("Verification failed");
						DeleteAndNullify!(mVerifyData);
					}
					else if (mReadProgramData != null)
					{
						//int
						File.WriteAll("read.bin", mReadProgramData);
						DeleteAndNullify!(mReadProgramData);
					}
				}

				mOutputLineData.Remove(0, crPos + 1);
			}

			if (mProcess?.HasExited == true)
			{
				int exitCode = mProcess.ExitCode;

				KillProcess();

				if (exitCode != 0)
					mHadError = true;

				if ((mPendingMonitor) && (exitCode == 0))
					DoMonitor();
			}

			using (mMonitor.Enter())
			{
				/*if (mUpdateCnt == 100)
				{
					mInData.Append("echo Hello\n");
					NOP!();
				}*/

				DataLoop: while (!mOutputData.IsEmpty)
				{
					if (mBoard.mContent.Paused)
					{
						break;
					}
					else
					{
						StringView insertText = mOutputData;

						int escPos = insertText.IndexOf('\x1B');

						if (escPos >= 0)
						{
							if (escPos == 0)
							{
								if (insertText.Length == 1)
									break;

								if (insertText[1] == '[')
								{
									bool isValid = true;
									int32 prevNum = 0;
									int32 num = 0;

									int32 i = 2;
									while (true)
									{
										bool ansiDone = false;

										if (i >= insertText.Length)
										{
											break DataLoop;
										}

										char8 c = insertText[i++];
										if ((c >= '0') && (c <= '9'))
										{
											num *= 10;
											num += c - '0';
										}
										else if (c == ';')
										{
											prevNum = num;
											num = 0;
										}
										else if (c == 'm')
										{
											//Debug.WriteLine($"Color Code: {prevNum} {num}");

											// Color
											if (num == 0)
												num = 37;

											if ((num >= 30) && (num <= 37) && (prevNum >= 0) && (prevNum <= 1))
											{
												mBoard.mContent.mColor = (num - 30) + prevNum * 8;
												ansiDone = true;
											}
											else
												isValid = false;
										}
										else
											isValid = false;

										if (ansiDone)
										{
											mOutputData.Remove(0, i);
											continue DataLoop;
										}

										if (!isValid)
										{
											insertText.RemoveToEnd(i - 1);
											break;
										}
									}
								}

							}
							else
							{
								insertText.RemoveToEnd(escPos);
							}
						}

						//Debug.WriteLine($"Inserting: {insertText}\n");

						mBoard.mContent.mInserting = true;
						mBoard.mContent.InsertAtCursor(scope .(insertText));
						mBoard.mContent.mInserting = false;

						//Debug.Write(mOutputData);
						//Debug.Flush();
						//mOutputData.Clear();

						mOutputData.Remove(0, insertText.Length);
					}
				}
			}
		}

		public void Fail(String text)
		{
#if CLI
			Console.WriteLine("ERROR: {0}", text);
			return;
#endif

#unwarn
			//Debug.Assert(Thread.CurrentThread == mMainThread);

		    if (mMainWindow == null)
		    {
		        //Internal.FatalError(StackStringFormat!("FAILED: {0}", text));
				Windows.MessageBoxA(0, text, "FATAL ERROR", 0);
				return;
		    }

		    //Beep(MessageBeepType.Error);

		    Dialog dialog = ThemeFactory.mDefault.CreateDialog("ERROR", text, DarkTheme.sDarkTheme.mIconError);
		    dialog.mDefaultButton = dialog.AddButton("OK");
		    dialog.mEscButton = dialog.mDefaultButton;
		    dialog.PopupWindow(mMainWindow);

			/*if (addWidget != null)
			{
				dialog.AddWidget(addWidget);
				addWidget.mY = dialog.mHeight - 60;
				addWidget.mX = 90;
			}*/
		}
	}

	static
	{
		public static TBApp gApp;
	}
}

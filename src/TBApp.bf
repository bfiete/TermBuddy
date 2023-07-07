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

		public class PendingInData
		{
			public String mData ~ delete _;
			public int32 mDelay;
			public bool mAwaitingContinue;
			public int32 mPrevSend;
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
		public int32 mBytesSent;
		public bool mPendingMonitor;
		public ViewMode mViewMode;
		public bool mHadError;
		public String mProgramFilePath = new .() ~ delete _;
		public String mResFilePath = new .() ~ delete _;
		public List<PendingInData> mPendingInData = new .() ~ delete _;
		public PendingInData mCurInData ~ delete _;
		public List<uint8> mVerifyData ~ delete _;
		public List<uint8> mReadProgramData ~ delete _;
		public String mOutputLineData = new .() ~ delete _;
		public SerialPort mSerialPort ~ delete _;

		public this()
		{
			gApp = this;
		}

		void OpenCom()
		{
			delete mSerialPort;
			mSerialPort = new SerialPort();
			if (mSerialPort.Open(3) case .Err)
			{
				Fail("Failed to open COM3");
				return;
			}
		}

		void CloseCom()
		{
			DeleteAndNullify!(mSerialPort);
			mBytesSent = 0;
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
			mBoard.mContent.mInserting = true;
			mBoard.mContent.Paused = false;
			mBoard.mContent.ClearText();
			mBoard.mContent.mContentCursorPos = 0;
			mBoard.mContent.CursorTextPos = 0;
			mBoard.mContent.mInserting = false;
			mOutputData.Clear();
		}

		public void ResetConsole()
		{
			ClearOutput();
			mBoard.mContent.mColor = 7;
			mInData.Clear();
			mPendingInData.ClearAndDeleteItems();
			mOutputLineData.Clear();
			mBytesSent = 0;
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

			//mInData.Append("\"C:\\Espressif\\idf_cmd_init.bat\" esp-idf-e91d384503485fbb54f6ce3d11e841fe\n");
			mInData.Append("\"C:\\Espressif\\idf_cmd_init.bat\" esp-idf-57b6d67bb026a1bc6f3a56f94687e2fe\n");

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

			var cwd = Directory.GetCurrentDirectory(.. scope .());

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
			mMainWindow = new WidgetWindow(null, scope $"TermBuddy - {cwd}", 32, 32, 1024, 768, windowFlags, mBoard);
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

		public void DoWorkspace()
		{
			FolderBrowserDialog dialog = scope .();
			dialog.SelectedPath = Directory.GetCurrentDirectory(.. scope .());
			if (dialog.ShowDialog() case .Err)
				return;

			if (!dialog.SelectedPath.IsEmpty)
				Directory.SetCurrentDirectory(dialog.SelectedPath).IgnoreError();
		}

		public void DoBuild()
		{
			if (File.Exists("build.bat"))
				SpawnIDF("build.bat");
			else
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

			CloseCom();
			OpenCom();
		}

		public void DoBuildAndMonitor()
		{
			if (File.Exists("build.bat"))
				SpawnIDF("build.bat\nidf.py -p COM3 flash");
			else
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

		public void FlashWrite(StringView kind, List<uint8> data)
		{
			int32 hash = 0;
			for (int i < data.Count)
				Hash(data[i], ref hash);

			int pendingLength = 0;

			PendingInData pendingInData = new .();
			mPendingInData.Add(pendingInData);
			pendingInData.mData = new String();
			pendingInData.mAwaitingContinue = true;

			void Enc(char8 c)
			{
				pendingInData.mData.Append(c);
			}

			int zeroCount = 0;
			void FlushZeros()
			{
				while (zeroCount > 0)
				{
					int encodeZero = Math.Min(zeroCount, 39);
					Enc('!' + encodeZero);
					zeroCount -= encodeZero;
				}
			}

			bool doCompress = true;
			for (int i < data.Count)
			{
				uint8 val = data[i];
				if ((val == 0) && (doCompress))
				{
					zeroCount++;
				}
				else
				{
					FlushZeros();
					if ((val & 0xF0 == 0) && (doCompress))
					{
						Enc('Y' + (val & 0x0F));
					}
					else if ((val & 0x0F == 0) && (doCompress))
					{
						Enc('i' + (val>>4));
					}
					else
					{
						Enc('I' + (val & 0x0F));
						Enc('I' + (val >> 4));
					}
				}

				//if (pendingInData.mData.Length > 0x10000 - 4)
				//if (pendingInData.mData.Length > 25000)
				if (pendingInData.mData.Length > 4000)
				{
					pendingInData.mData.Append('z');
					int32 prevSend = (.)pendingInData.mData.Length;
					pendingLength += pendingInData.mData.Length;
					pendingInData = new .();
					mPendingInData.Add(pendingInData);
					pendingInData.mData = new String();
					pendingInData.mAwaitingContinue = true;
					pendingInData.mPrevSend = prevSend;
				}
			}
			FlushZeros();
			pendingInData.mData.Append('z');
			pendingLength += pendingInData.mData.Length;

			mInData.AppendF($":{kind} {data.Count} {pendingLength} {hash}\n");
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
			if (mProgramFilePath.IsEmpty)
			{
				DoProgram();
				return;
			}

			mBoard.mContent.Paused = false;

			List<uint8> data = scope .();
			if (File.ReadAll(mProgramFilePath, data) case .Err)
			{
				Fail(scope $"Failed to read '{mProgramFilePath}'");
				return;
			}

			FlashWrite("PROGRAM", data);
		}

		public bool GetResPath()
		{
			if (mViewMode != .Monitor)
				DoMonitor();

			var dialog = scope OpenFileDialog();
			dialog.SetFilter("All files (*.*)|*.*");
			dialog.InitialDirectory = mInstallDir;
			dialog.Title = "Open Resource";
			let result = dialog.ShowDialog();
			if ((result case .Err) || (dialog.FileNames.Count == 0))
			{
				return false;
			}

			mResFilePath.Set(dialog.FileNames[0]);
			return true;
		}

		public void DoResWrite()
		{
			if (!GetResPath())
				return;
			if (mResFilePath.IsEmpty)
				return;
			DoResRewrite();
		}

		public void DoResRewrite()
		{
			if (mResFilePath.IsEmpty)
			{
				DoResWrite();
				return;
			}

			mBoard.mContent.Paused = false;

			List<uint8> data = scope .();
			if (File.ReadAll(mResFilePath, data) case .Err)
			{
				Fail(scope $"Failed to read '{mResFilePath}'");
				return;
			}

			FlashWrite("RESDATA", data);
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
			//EscapeCommFunction(mComHandle, 3/*SETRTS*/);
			mSerialPort.RTS = true;
			Thread.Sleep(20);
			//EscapeCommFunction(mComHandle, 6/*CLRDTR*/);
			//EscapeCommFunction(mComHandle, 4/*CLRRTS*/);
			mSerialPort.RTS = false;
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
				if ((--pendingInData.mDelay <= 0) && (!pendingInData.mAwaitingContinue))
				{
					mInData.Append(pendingInData.mData);
					mPendingInData.PopFront();

					delete mCurInData;
					mCurInData = pendingInData;
				}
			}

			if (mSerialPort != null)
			{
				uint8[1024] data = ?;
				int numBytesRead = mSerialPort.Read(data).GetValueOrDefault();
				if (numBytesRead > 0)
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
					int32 len = (.)Math.Min(mInData.Length, 256);
					//int32 len = (.)Math.Min(mInData.Length, 16);

					int32 numBytesWritten = mSerialPort.Write(.((uint8*)mInData.Ptr, len)).GetValueOrDefault();
					//result = Windows.WriteFile(mComHandle, (.)mInData.Ptr, len, var numBytesWritten, null);
					//if (result > 0)
					if (numBytesWritten > 0)
					{
						mBytesSent += numBytesWritten;
						mInData.Remove(0, numBytesWritten);
					}
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

				if (line.StartsWith(":CONTINUE"))
				{
					int32 prevSend = 0;
					if (line.Contains(' '))
						prevSend = int32.Parse(line.Substring(":CONTINUE ".Length)).GetValueOrDefault();

					if (!mPendingInData.IsEmpty)
					{
						var pendingInData = mPendingInData.Front;
						if ((pendingInData.mPrevSend != 0) && (pendingInData.mPrevSend != prevSend))
						{
							OutputText(scope $"FAILED TRANSFER: Receiver received {prevSend} bytes but expected {pendingInData.mPrevSend}\n");
							mInData.Append('y'); // Resending block...
							mPendingInData.Add(mCurInData);
							mCurInData = null;
						}
						else
						{
							pendingInData.mAwaitingContinue = false;
						}
					}
				}
				else if (line.StartsWith(":RESEND"))
				{
					if (mCurInData != null)
					{
						mPendingInData.Insert(0, mCurInData);
						delete mCurInData;
					}
				}
				else if (line.StartsWith(":READ SIZE "))
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
						String matchError = scope .();
						if (mVerifyData.Count != mReadProgramData.Count)
							matchError.Set(scope $"Expected {mVerifyData.Count} bytes but got {mReadProgramData.Count}");
						else
						{
							for (int i < mVerifyData.Count)
								if (mVerifyData[i] != mReadProgramData[i])
								{
									matchError.Set(scope $"Data mismatch at 0x{i:X}");
									break;
								}
						}

						if (!matchError.IsEmpty)
						{
							Fail(scope $"Verification failed: {matchError}\nRead data written to read.bin");
							File.WriteAll("read.bin", mReadProgramData).IgnoreError();
						}
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

						OutputText(insertText);

						//Debug.Write(mOutputData);
						//Debug.Flush();
						//mOutputData.Clear();

						mOutputData.Remove(0, insertText.Length);
					}
				}
			}
		}

		public void OutputText(StringView text)
		{
			mBoard.mContent.mInserting = true;
			mBoard.mContent.InsertAtCursor(.. scope String()..Append(text));
			mBoard.mContent.mInserting = false;
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

using System;

namespace TermBuddy;

class SerialPort
{
	[CRepr]
	struct COMMTIMEOUTS
	{
		public uint32 ReadIntervalTimeout;
		public uint32 ReadTotalTimeoutMultiplier;
		public uint32 ReadTotalTimeoutConstant;
		public uint32 WriteTotalTimeoutMultiplier;
		public uint32 WriteTotalTimeoutConstant;
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

	public Windows.FileHandle mComHandle;

	public bool RTS
	{
		set
		{
			if (value)
				EscapeCommFunction(mComHandle, 3/*SETRTS*/);
			else
				EscapeCommFunction(mComHandle, 4/*CLRRTS*/);
		}
	}

	public this()
	{

	}

	public ~this()
	{
		if (mComHandle.IsInvalid)
			return;

		Windows.CloseHandle(mComHandle);
	}

	public Result<void> Open(int comPort, int baudRate = 115200, int parity = 0, int byteSize = 8)
	{
		mComHandle = Windows.CreateFileA(scope $"\\\\.\\COM{comPort}", Windows.GENERIC_READ | Windows.GENERIC_WRITE, 0, null, .Open, 0x00000080, default);
		if (mComHandle.IsInvalid)
			return .Err;

		DCB dcb = .();
		GetCommState(mComHandle, out dcb);

		dcb = default;
		dcb.DCBlength = 28;
		dcb.BaudRate = (.)baudRate;
		dcb.mFlags = 1;
		dcb.XoffLim = 512;
		dcb.ByteSize = (.)byteSize;
		dcb.StopBits = 0;
		dcb.Parity = (.)parity;
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

		return .Ok;
	}

	public Result<int32> Read(Span<uint8> span)
	{
		int32 result = Windows.ReadFile(mComHandle, span.Ptr, (.)span.Length, var numBytesRead, null);
		if (result < 0)
			return .Err;
		return numBytesRead;
	}

	public Result<int32> Write(Span<uint8> span)
	{
		int32 result = Windows.WriteFile(mComHandle, span.Ptr, (.)span.Length, var numBytesRead, null);
		if (result < 0)
			return .Err;
		return numBytesRead;
	}
}
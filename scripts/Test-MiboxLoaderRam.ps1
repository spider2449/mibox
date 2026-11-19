param([Parameter(Mandatory=$true)][ValidateSet('SelfTest','BulkTest','Status','Reset','UploadCandidate','BootCandidate','UploadAndBoot')][string]$Action,[switch]$Bulk,
    [ValidateSet('Baseline','Restart','Health','Hardware','Hardware2','Hardware3','Capture','DisplayCapture','Console','ContainerKernel','ContainerKernel2','DockerKernel','DockerKernel2','FailSafe','FaultPanic','FaultUsb','FaultHang','FaultKPanic','Loader','Slim','SlimKernelDev','SlimKernelDev2','SlimKernelDev3','SlimKernelDev4')][string]$Candidate='Baseline',[switch]$VerifyOnly,
    [ValidateRange(3000,15000)][int]$ControlTimeoutMilliseconds=3000)
$ErrorActionPreference='Stop'
if($Candidate -in @('Restart','Health','Hardware','Hardware2','Hardware3','Capture','DisplayCapture','Console','ContainerKernel','ContainerKernel2','DockerKernel','DockerKernel2','FailSafe','FaultPanic','FaultUsb','FaultHang','FaultKPanic','Loader','Slim','SlimKernelDev','SlimKernelDev2','SlimKernelDev3','SlimKernelDev4') -and $Action -ne 'UploadAndBoot') {
    throw 'Versioned candidate requires full upload/readback/boot in one session'
}
if($VerifyOnly -and $Action -notin @('UploadCandidate','BootCandidate','UploadAndBoot')) {
    throw 'VerifyOnly requires a candidate image action'
}
# Bulk mode uses bulk OUT (WR_LARGE_MEM) only. Bulk IN stays unused: an armed
# but undrained bulk IN request blocks EP0 IN replies in the loader's shared
# non-periodic TX FIFO, and the only correctly addressed bulk IN read (2026-11-14)
# timed out. Bulk uploads are verified by the loader's own crc32 command plus
# sampled EP0 reads, so BootCandidate (readback-only) keeps the control channel.
if($Bulk -and $Action -in @('BootCandidate','SelfTest','Status','Reset')) {
    throw 'Bulk applies only to UploadCandidate, UploadAndBoot and BulkTest'
}
if(-not ('MiboxLoader.RamTest' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace MiboxLoader {
  public sealed class RamResult {
    public bool Found; public string DevicePath; public string VidPid;
    public string IdentifyHex; public bool VendorRequestSent; public string InterfaceGuid;
    public string BootBufferAddress; public string BootBufferHex;
    public string Action; public bool PatternVerified; public bool OriginalRestored;
    public int VerifiedBytes; public string VerifiedSha256; public bool CommandAttempted;
    public bool CommandTransferCompleted;
    public string StatusHex; public string StatusText;
    public bool BulkMode;
    public string VerificationMethod; public string SourceSha256;
    public string ExpectedCrc32; public string DeviceCrc32; public string DeviceCrc32Order;
    public string CrcCommandStatus; public int SampledBlocks; public double UploadSeconds;
    public int ControlTimeoutMilliseconds;
  }
  public static class RamTest {
    [StructLayout(LayoutKind.Sequential)] struct InterfaceData {
      public uint Size; public Guid ClassGuid; public uint Flags; public IntPtr Reserved;
    }
    [StructLayout(LayoutKind.Sequential, Pack=1)] struct SetupPacket {
      public byte Type; public byte Request; public ushort Value; public ushort Index; public ushort Length;
    }
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid guid, IntPtr enumerator, IntPtr parent, uint flags);
    [DllImport("setupapi.dll", SetLastError=true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr device, ref Guid guid, uint index, ref InterfaceData data);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref InterfaceData data, IntPtr detail, uint size, out uint required, IntPtr device);
    [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("winusb.dll",SetLastError=true)] static extern bool WinUsb_Initialize(SafeFileHandle file,out IntPtr handle);
    [DllImport("winusb.dll",SetLastError=true)] static extern bool WinUsb_Free(IntPtr handle);
    [StructLayout(LayoutKind.Sequential)] struct PipeInfo {public int Type;public byte Id;public ushort MaxPacket;public byte Interval;}
    [DllImport("winusb.dll",SetLastError=true)] static extern bool WinUsb_QueryPipe(IntPtr handle,byte alternate,byte index,out PipeInfo info);
    [DllImport("winusb.dll",SetLastError=true)] static extern bool WinUsb_ReadPipe(IntPtr handle,byte pipe,byte[] data,uint length,out uint count,IntPtr overlapped);
    [DllImport("winusb.dll",SetLastError=true)] static extern bool WinUsb_WritePipe(IntPtr handle,byte pipe,byte[] data,uint length,out uint count,IntPtr overlapped);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_GetDescriptor(IntPtr handle,byte type,byte index,ushort language,byte[] data,uint size,out uint transferred);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_SetPipePolicy(IntPtr handle,byte pipe,uint type,uint size,ref uint value);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_ControlTransfer(IntPtr handle,SetupPacket packet,byte[] data,uint size,out uint transferred,IntPtr overlapped);
    static void Check(bool ok,string operation) {
      if(!ok) { int error=Marshal.GetLastWin32Error(); throw new Win32Exception(error,operation+" (Win32 "+error+")"); }
    }
    static byte[] Read(IntPtr handle,uint address,int length) {
      if(address<0x82000000 || (ulong)address+(uint)length>0x82800000 || length<1 || length>64)
        throw new Exception("RAM read outside fixed boot buffer");
      byte[] bytes=new byte[length]; uint count;
      SetupPacket packet=new SetupPacket {Type=0xc0,Request=2,Value=(ushort)(address>>16),Index=(ushort)(address&65535),Length=(ushort)length};
      Check(WinUsb_ControlTransfer(handle,packet,bytes,(uint)length,out count,IntPtr.Zero),"Read RAM 0x"+address.ToString("x8"));
      if(count!=length) throw new Exception("Short RAM read");
      return bytes;
    }
    static void Write(IntPtr handle,uint address,byte[] bytes) {
      if(address<0x82000000 || (ulong)address+(uint)bytes.Length>0x82800000 || bytes.Length<1 || bytes.Length>64)
        throw new Exception("RAM write outside fixed boot buffer");
      uint count;
      SetupPacket packet=new SetupPacket {Type=0x40,Request=1,Value=(ushort)(address>>16),Index=(ushort)(address&65535),Length=(ushort)bytes.Length};
      Check(WinUsb_ControlTransfer(handle,packet,bytes,(uint)bytes.Length,out count,IntPtr.Zero),"Write RAM 0x"+address.ToString("x8"));
      if(count!=bytes.Length) throw new Exception("Short RAM write");
    }
    static bool Same(byte[] a,byte[] b) {
      if(a.Length!=b.Length)return false;
      for(int i=0;i<a.Length;i++)if(a[i]!=b[i])return false;
      return true;
    }
    static string Hash(byte[] bytes) {
      using(SHA256 sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant();
    }
    // Bulk OUT write. Reference WR_LARGE_MEM: EP0 0x40/0x11 with a 16-byte
    // little-endian address/length data stage, then the loader arms bulk OUT
    // 0x02 in 4 KiB device blocks (xferNeedReply=0, no handshake). WinUSB
    // PipeId is the endpoint address. Not the storage DOWNLOAD protocol.
    static void WriteBulk(IntPtr handle,uint address,byte[] data,int offset,int length) {
      if(address<0x82000000 || (ulong)address+(uint)length>0x82800000 || length<1 || length>4096 || (length%64)!=0)
        throw new Exception("Bulk transfer outside fixed RAM window/block limit");
      byte[] header=new byte[16];BitConverter.GetBytes(address).CopyTo(header,0);BitConverter.GetBytes(length).CopyTo(header,4);
      SetupPacket packet=new SetupPacket {Type=0x40,Request=0x11,Value=(ushort)length,Index=1,Length=16};uint count;
      Check(WinUsb_ControlTransfer(handle,packet,header,16,out count,IntPtr.Zero),"Set up RAM bulk write 0x"+address.ToString("x8"));
      if(count!=16)throw new Exception("Short bulk setup");
      byte[] chunk=data;
      if(offset!=0 || length!=data.Length) {chunk=new byte[length];Buffer.BlockCopy(data,offset,chunk,0,length);}
      Check(WinUsb_WritePipe(handle,0x02,chunk,(uint)length,out count,IntPtr.Zero),"Bulk RAM write 0x"+address.ToString("x8"));
      if(count!=length)throw new Exception("Short RAM bulk transfer");
    }
    // Single fixed result slot directly after the 8 MiB boot buffer, used only
    // by the fixed crc32 verification command below.
    const uint CrcSlot=0x82800000;
    static byte[] ReadCrcSlot(IntPtr handle) {
      byte[] bytes=new byte[64]; uint count;
      SetupPacket packet=new SetupPacket {Type=0xc0,Request=2,Value=(ushort)(CrcSlot>>16),Index=(ushort)(CrcSlot&65535),Length=64};
      Check(WinUsb_ControlTransfer(handle,packet,bytes,64,out count,IntPtr.Zero),"Read crc32 result slot");
      if(count!=64)throw new Exception("Short crc32 slot read");
      return bytes;
    }
    static void WriteCrcSlot(IntPtr handle,byte[] bytes) {
      if(bytes.Length!=64)throw new Exception("crc32 slot sentinel must be 64 bytes");
      uint count;
      SetupPacket packet=new SetupPacket {Type=0x40,Request=1,Value=(ushort)(CrcSlot>>16),Index=(ushort)(CrcSlot&65535),Length=64};
      Check(WinUsb_ControlTransfer(handle,packet,bytes,64,out count,IntPtr.Zero),"Write crc32 slot sentinel");
      if(count!=64)throw new Exception("Short crc32 slot write");
    }
    static uint Crc32(byte[] data) {
      uint[] table=new uint[256];
      for(uint n=0;n<256;n++){uint c=n;for(int k=0;k<8;k++)c=(c&1)!=0?0xedb88320u^(c>>1):c>>1;table[n]=c;}
      uint crc=0xffffffffu;
      foreach(byte b in data)crc=table[(crc^b)&0xff]^(crc>>8);
      return crc^0xffffffffu;
    }
    static string TplCommand(IntPtr handle,string command) {
      byte[] data=new byte[64];Encoding.ASCII.GetBytes(command).CopyTo(data,0);uint count;
      SetupPacket packet=new SetupPacket {Type=0x40,Request=0x30,Value=0,Index=1,Length=64};
      Check(WinUsb_ControlTransfer(handle,packet,data,64,out count,IntPtr.Zero),"TPL command");
      if(count!=64)throw new Exception("Short TPL command");
      byte[] status=new byte[64];
      SetupPacket query=new SetupPacket {Type=0xc0,Request=0x31,Value=0,Index=0,Length=64};
      Check(WinUsb_ControlTransfer(handle,query,status,64,out count,IntPtr.Zero),"Read TPL command status");
      if(count!=64)throw new Exception("Short TPL status");
      return Encoding.ASCII.GetString(status).TrimEnd('\0');
    }
    // Fixed command, fixed range: u-boot do_mem_crc stores the 32-bit result
    // natively at the third argument. No storage or environment access.
    static void VerifyByCrc(IntPtr handle,byte[] image,RamResult result) {
      if(image.Length!=8388608)throw new Exception("crc32 verification requires the 8 MiB image");
      byte[] sentinel=new byte[64];for(int i=0;i<64;i++)sentinel[i]=(byte)(0x5a^i);
      WriteCrcSlot(handle,sentinel);
      if(!Same(sentinel,ReadCrcSlot(handle)))throw new Exception("crc32 slot sentinel not written");
      uint expected=Crc32(image);result.ExpectedCrc32=expected.ToString("x8");
      result.CrcCommandStatus=TplCommand(handle,"crc32 0x82000000 0x800000 0x82800000");
      if(!result.CrcCommandStatus.StartsWith("success"))throw new Exception("crc32 command failed: "+result.CrcCommandStatus);
      byte[] slot=ReadCrcSlot(handle);
      for(int i=4;i<64;i++)if(slot[i]!=sentinel[i])throw new Exception("crc32 wrote outside its 4-byte result");
      uint little=BitConverter.ToUInt32(slot,0);
      uint big=(uint)(slot[0]<<24|slot[1]<<16|slot[2]<<8|slot[3]);
      result.DeviceCrc32=little.ToString("x8");
      if(little==expected)result.DeviceCrc32Order="little-endian";
      else if(big==expected){result.DeviceCrc32Order="big-endian";result.DeviceCrc32=big.ToString("x8");}
      else throw new Exception("Device crc32 "+little.ToString("x8")+" != expected "+result.ExpectedCrc32);
    }
    public static string ValidateImage(byte[] image,string preset) {
      string expected;
      if(preset=="Baseline")expected="f05adbc3d79c8f41be7fef1145f6111f436d35921b7051722ae5195ae7624bba";
      else if(preset=="Restart")expected="5608fa36caa28a7acf7a647b53db5d2775aaceb44730896f87da03f8ba6047fa";
      else if(preset=="Health")expected="2788822cb79c3808ef6f4bb067fc4b57a033319c5fa0e93ecaec6874c8879bc3";
      else if(preset=="Hardware")expected="ac2939921a9fb44f5c918c3c8f7f1e5f6dff2dbd48d6142583b18f4c6976cd28";
      else if(preset=="Hardware2")expected="38ffab4483d5470091468a47a1f2397337f2cdb3f7858fe2e4cf015fdeb8afa1";
      else if(preset=="Hardware3")expected="5f6a5654e5603c7abaeb9dca21996bc5a6e3bc0a83b650c8e0e347de100fdd55";
      else if(preset=="Capture")expected="03c2fec77ece8dada455a4be2b818ee377c4957d56ce97a3675406243832f53b";
      else if(preset=="DisplayCapture")expected="19c7064bc3e389a8f63ba70847ae7628e8366d38644b187f9cec89e33dccf2fb";
      else if(preset=="Console")expected="4629deefd4e5e0f1902a54158ef01c7ad67156ef87946fb6d87c7070ba5da7c0";
      else if(preset=="ContainerKernel")expected="dce6ac31ab47bce5dfee987cfd1cac1b40f9e200bd2d953f768113c77563e35e";
      else if(preset=="ContainerKernel2")expected="fb1333d9d36c92577ef17643590f67cea596e7d76df33ff8238aa7fcb192f6a6";
      else if(preset=="DockerKernel")expected="3d0be1a75f59e1ecd21459768b603cef8c3c769e0e31f69445d68cf34bf3f2dc";
      else if(preset=="DockerKernel2")expected="13794e4423287cc12ea2b63bff22a937b156d70d54fb4141ba9342ea4b19c1fa";
      else if(preset=="FailSafe")expected="f5e9cd6b8677504429340dcc1f51261fd10108020366461c0cede198afcd6d93";
      else if(preset=="FaultPanic")expected="426731f53fccc0e76a402396b655ca85d1ba21178679dfdd3e4cb1b3afc63a0a";
      else if(preset=="FaultUsb")expected="97a9b47bc975eb79e3c1c8355780aa6f5c5d0877974097c7c3c5a10a1e84b987";
      else if(preset=="FaultHang")expected="987851820bbe33d3aaef9668ed56f8cbdc4431b9c0afbaf78aaa0a1ffac8130b";
      else if(preset=="FaultKPanic")expected="e1a698204599c9cf5e407604099646914e20cd5e771911de3bccc52572c6fdb4";
      else if(preset=="Loader")expected="9c45436205964fabb2f2a113a7b65be524a3f1acde0933f2c5a4b1b460c8b58c";
      else if(preset=="Slim")expected="f11de99e04362e5cb6cb4c84aa077bc534613185ea98c3461e77d229e71e1505";
      else if(preset=="SlimKernelDev")expected="7279a88a6b2755dbc44c903a312ce3efcc77d1295d3565faee9850108712c0c7";
      else if(preset=="SlimKernelDev2")expected="11b85b1fcb35edc9062f2227a9394dec29557ab741f5abb69483da52f49f560e";
      else if(preset=="SlimKernelDev3")expected="6f500cfdc256517455d91568d1612dd93bff60a31b1ffb181766b86f3c031738";
      else if(preset=="SlimKernelDev4")expected="b11422d78b8e0cd54b565bd5dd61d065509cae20d4423c3ae45296d8dde0de76";
      else throw new Exception("Unknown pinned candidate");
      if(image==null || image.Length!=8388608 || Hash(image)!=expected)throw new Exception("Candidate hash/size mismatch before USB access");
      return expected;
    }
    public static RamResult Run(string action,byte[] image,string interfaceGuid,bool bulk,string preset,int controlTimeout) {
      if(controlTimeout<3000 || controlTimeout>15000)throw new Exception("Control timeout outside bounded range");
      if(action!="SelfTest" && action!="BulkTest" && action!="Status" && action!="Reset" && action!="UploadCandidate" && action!="BootCandidate" && action!="UploadAndBoot")throw new Exception("Unknown action");
      string expected=null;
      if(action=="UploadCandidate" || action=="BootCandidate" || action=="UploadAndBoot") {
        expected=ValidateImage(image,preset);
      }
      // Dedicated GUID from the checked-in, exact-device Zadig preset.
      Guid guid=new Guid(interfaceGuid);
      IntPtr set=SetupDiGetClassDevs(ref guid,IntPtr.Zero,IntPtr.Zero,0x12);
      if(set==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
      string path=null;
      try {
        for(uint index=0;index<64;index++) {
          InterfaceData item=new InterfaceData(); item.Size=(uint)Marshal.SizeOf(typeof(InterfaceData));
          if(!SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref guid,index,ref item)) {
            int error=Marshal.GetLastWin32Error();
            if(error==259) break;
            throw new Win32Exception(error,"Enumerate loader interface");
          }
          uint needed;
          SetupDiGetDeviceInterfaceDetail(set,ref item,IntPtr.Zero,0,out needed,IntPtr.Zero);
          if(needed<8 || needed>16384) throw new Exception("Invalid interface path size");
          IntPtr detail=Marshal.AllocHGlobal((int)needed);
          try {
            Marshal.WriteInt32(detail,IntPtr.Size==8?8:6);
            Check(SetupDiGetDeviceInterfaceDetail(set,ref item,detail,needed,out needed,IntPtr.Zero),"Get loader path");
            string candidate=Marshal.PtrToStringUni(IntPtr.Add(detail,4));
            if(Regex.IsMatch(candidate,@"vid_1b8e&pid_c003(?:#|&)",RegexOptions.IgnoreCase)) {
              if(path!=null) throw new Exception("Multiple target loaders present; refuse ambiguous selection");
              path=candidate;
            }
          } finally {Marshal.FreeHGlobal(detail);}
        }
      } finally {SetupDiDestroyDeviceInfoList(set);}
      if(path==null) return new RamResult {Found=false,VendorRequestSent=false};
      using(SafeFileHandle file=CreateFile(path,0xc0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero)) {
        if(file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"Open exact loader interface");
        IntPtr handle; Check(WinUsb_Initialize(file,out handle),"Initialize WinUSB");
        try {
          byte[] descriptor=new byte[18]; uint count;
          Check(WinUsb_GetDescriptor(handle,1,0,0,descriptor,18,out count),"Read standard device descriptor");
          if(count!=18 || descriptor[0]!=18 || descriptor[1]!=1 || BitConverter.ToUInt16(descriptor,8)!=0x1b8e || BitConverter.ToUInt16(descriptor,10)!=0xc003)
            throw new Exception("Descriptor does not match scoped loader; no vendor request sent");
          RamResult result=new RamResult {Found=true,DevicePath=path,VidPid="1B8E:C003",VendorRequestSent=false,InterfaceGuid=guid.ToString(),Action=action,ControlTimeoutMilliseconds=controlTimeout};
          result.BulkMode=bulk || action=="BulkTest";
          if(result.BulkMode) {
            bool input=false,output=false;
            for(byte n=0;n<2;n++) {PipeInfo info;Check(WinUsb_QueryPipe(handle,0,n,out info),"Query actual bulk endpoint");
              if(info.Type!=2)throw new Exception("Unexpected endpoint type");
              if(info.Id==0x81)input=true;else if(info.Id==2)output=true;else throw new Exception("Unexpected bulk endpoint");
              uint bounded=3000;Check(WinUsb_SetPipePolicy(handle,info.Id,3,4,ref bounded),"Set bulk timeout");
            }
            if(!input || !output)throw new Exception("Expected bulk pipes absent");
          }
          {
            uint timeout=(uint)controlTimeout; Check(WinUsb_SetPipePolicy(handle,0,3,4,ref timeout),"Set bounded control timeout");
            // Reference AM_REQ_IDENTIFY_HOST: vendor IN 0x20, four-byte version/stage response.
            SetupPacket request=new SetupPacket {Type=0xc0,Request=0x20,Value=0,Index=0,Length=4};
            byte[] response=new byte[4];
            Check(WinUsb_ControlTransfer(handle,request,response,4,out count,IntPtr.Zero),"Read loader identification");
            if(count!=4) throw new Exception("Unexpected identify length");
            result.IdentifyHex=BitConverter.ToString(response); result.VendorRequestSent=true;
            {
              if(result.IdentifyHex!="00-08-00-10") throw new Exception("Unverified loader version; RAM read refused");
              // Saved device environment loadaddr=0x82000000. Fixed 64-byte RAM read;
              // below the reference implementation's 512-byte EP0 scratch limit.
              byte[] memory=new byte[64];
              SetupPacket read=new SetupPacket {Type=0xc0,Request=0x02,Value=0x8200,Index=0,Length=64};
              Check(WinUsb_ControlTransfer(handle,read,memory,64,out count,IntPtr.Zero),"Read saved boot buffer");
              if(count!=64) throw new Exception("Unexpected boot buffer read length");
              result.BootBufferAddress="0x82000000"; result.BootBufferHex=BitConverter.ToString(memory);
            }
          }
          if(action=="Status") {
            byte[] status=new byte[64];
            SetupPacket packet=new SetupPacket {Type=0xc0,Request=0x31,Value=0,Index=0,Length=64};
            Check(WinUsb_ControlTransfer(handle,packet,status,64,out count,IntPtr.Zero),"Read TPL command status");
            if(count!=64)throw new Exception("Short command status");
            result.StatusHex=BitConverter.ToString(status);result.StatusText=Encoding.ASCII.GetString(status).TrimEnd('\0');
          }
          if(action=="SelfTest" || action=="BulkTest") {
            byte[] original=Read(handle,0x82000000,64);
            byte[] pattern=new byte[64];for(int i=0;i<pattern.Length;i++)pattern[i]=(byte)(i^0xa5);
            try {
              if(action=="BulkTest")WriteBulk(handle,0x82000000,pattern,0,64);else Write(handle,0x82000000,pattern);
              result.PatternVerified=Same(pattern,Read(handle,0x82000000,64));
              if(!result.PatternVerified)throw new Exception("RAM pattern mismatch");
            } finally {
              Write(handle,0x82000000,original);
              result.OriginalRestored=Same(original,Read(handle,0x82000000,64));
              if(!result.OriginalRestored)throw new Exception("Original RAM bytes not restored");
            }
          }
          if(bulk && (action=="UploadCandidate" || action=="UploadAndBoot")) {
            var clock=System.Diagnostics.Stopwatch.StartNew();
            for(int offset=0;offset<image.Length;offset+=4096) {
              WriteBulk(handle,0x82000000+(uint)offset,image,offset,4096);
              if((offset+4096)%1048576==0)Console.Error.WriteLine("Bulk-written RAM bytes: "+(offset+4096));
            }
            result.UploadSeconds=clock.Elapsed.TotalSeconds;
            // Sampled EP0 readback: the first 64 bytes of every 64 KiB plus the
            // final 64 bytes; any framing/offset error shows up here directly.
            int sampled=0;
            for(int offset=0;offset<=image.Length;offset+=65536) {
              int at=offset==image.Length?image.Length-64:offset;
              byte[] actual=Read(handle,0x82000000+(uint)at,64);
              for(int j=0;j<64;j++)if(actual[j]!=image[at+j])throw new Exception("Sampled RAM mismatch at "+(at+j));
              sampled++;
            }
            result.SampledBlocks=sampled;
            VerifyByCrc(handle,image,result);
            result.VerificationMethod="BulkOutCrc32";result.SourceSha256=expected;
            result.VerifiedBytes=image.Length;result.VerifiedSha256=null;
          }
          else if(action=="UploadCandidate" || action=="BootCandidate" || action=="UploadAndBoot") {
            result.VerificationMethod="ControlReadback";
            byte[] readback=new byte[image.Length];
            const int block=64;
            for(int offset=0;offset<image.Length;offset+=block) {
              if(action=="UploadCandidate" || action=="UploadAndBoot") {
                byte[] chunk=new byte[block];Buffer.BlockCopy(image,offset,chunk,0,block);
                Write(handle,0x82000000+(uint)offset,chunk);
              }
              byte[] actual=Read(handle,0x82000000+(uint)offset,block);
              Buffer.BlockCopy(actual,0,readback,offset,block);
              for(int j=0;j<block;j++)if(actual[j]!=image[offset+j])throw new Exception("RAM readback mismatch at "+(offset+j));
              if((offset+block)%262144==0)Console.Error.WriteLine("Verified RAM bytes: "+(offset+block));
            }
            result.VerifiedSha256=Hash(readback);result.VerifiedBytes=readback.Length;
            if(result.VerifiedSha256!=expected)throw new Exception("Full RAM SHA256 mismatch");
          }
          if(action=="Reset" || action=="BootCandidate" || action=="UploadAndBoot") {
            // No arbitrary command input; no storage/environment commands.
            string command=action=="Reset"?"reset":"bootm 0x82000000";
            byte[] data=new byte[64];Encoding.ASCII.GetBytes(command).CopyTo(data,0);
            SetupPacket packet=new SetupPacket {Type=0x40,Request=0x30,Value=0,Index=1,Length=64};
            result.CommandAttempted=true;
            // The reference disconnects USB during bootm/reset. Transfer failure
            // cannot establish command success; the observer must verify the next boot.
            bool completed=WinUsb_ControlTransfer(handle,packet,data,64,out count,IntPtr.Zero);
            result.CommandTransferCompleted=completed && count==64;
          }
          return result;
        } finally {WinUsb_Free(handle);}
      }
    }
  }
}
'@
}
$image=$null
if($Action -in @('UploadCandidate','BootCandidate','UploadAndBoot')) {
    $directory=switch($Candidate) {
        'Restart' {'mibox-boot-candidate-restart'}
        'Health' {'mibox-boot-candidate-health'}
        'Hardware' {'mibox-boot-candidate-hardware'}
        'Hardware2' {'mibox-boot-candidate-hardware2'}
        'Hardware3' {'mibox-boot-candidate-hardware3'}
        'Capture' {'mibox-boot-candidate-capture'}
        'DisplayCapture' {'mibox-boot-candidate-display-capture'}
        'Console' {'mibox-boot-candidate-console'}
        'ContainerKernel' {'mibox-boot-candidate-kernel'}
        'ContainerKernel2' {'mibox-boot-candidate-kernel2'}
        'DockerKernel' {'mibox-boot-candidate-docker'}
        'DockerKernel2' {'mibox-boot-candidate-docker2'}
        'FailSafe' {'mibox-boot-candidate-console-failsafe'}
        'FaultPanic' {'mibox-boot-candidate-console-fault-panic'}
        'FaultUsb' {'mibox-boot-candidate-console-fault-usb'}
        'FaultHang' {'mibox-boot-candidate-console-fault-hang'}
        'FaultKPanic' {'mibox-boot-candidate-console-fault-kpanic'}
        'Loader' {'mibox-boot-candidate-console-loader'}
        'Slim' {'mibox-boot-candidate-slim'}
        'SlimKernelDev' {'mibox-boot-candidate-slim-kernel-dev'}
        'SlimKernelDev2' {'mibox-boot-candidate-slim-kernel-dev2'}
        'SlimKernelDev3' {'mibox-boot-candidate-slim-kernel-dev3'}
        'SlimKernelDev4' {'mibox-boot-candidate-slim-kernel-dev4'}
        default {'mibox-boot-candidate'}
    }
    $candidatePath=Join-Path $PSScriptRoot ('../target/'+$directory+'/boot1-custom.NOT_READY.img')
    $image=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $candidatePath).Path)
    $validatedHash=[MiboxLoader.RamTest]::ValidateImage($image,$Candidate)
    if($VerifyOnly) {
        [ordered]@{Candidate=$Candidate;Bytes=$image.Length;Sha256=$validatedHash;UsbAccessed=$false} | ConvertTo-Json
        return
    }
}
$guids=@('86C80ED9-6F95-4FB7-ABFE-744BA77DDC25')
$registryRoot='HKLM:\SYSTEM\CurrentControlSet\Enum\USB\VID_1B8E&PID_C003'
if(Test-Path -LiteralPath $registryRoot) {
    foreach($instance in @(Get-ChildItem -LiteralPath $registryRoot)) {
        $parameters=Join-Path $instance.PSPath 'Device Parameters'
        foreach($text in @((Get-ItemProperty -LiteralPath $parameters -Name DeviceInterfaceGUIDs -ErrorAction SilentlyContinue).DeviceInterfaceGUIDs)) {
            $parsed=[guid]::Empty
            if([guid]::TryParse($text,[ref]$parsed)) {$guids+=$parsed.ToString()}
        }
    }
}
$result=$null
foreach($guid in @($guids | Select-Object -Unique)) {
    $result=[MiboxLoader.RamTest]::Run($Action,$image,$guid,[bool]$Bulk,$Candidate,$ControlTimeoutMilliseconds)
    if($result.Found) {break}
}
$result | ConvertTo-Json
if(-not $result.Found) {throw 'Loader interface absent'}

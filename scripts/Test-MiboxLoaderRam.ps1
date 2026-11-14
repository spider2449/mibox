param([Parameter(Mandatory=$true)][ValidateSet('SelfTest','BulkTest','Status','Reset','UploadCandidate','BootCandidate','UploadAndBoot')][string]$Action,[switch]$Bulk)
$ErrorActionPreference='Stop'
if($Bulk -and $Action -in @('UploadCandidate','BootCandidate','UploadAndBoot')) {
    throw 'Bulk image actions disabled: the physical BulkTest timed out; use the verified control channel'
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
    static byte[] TransferBulk(IntPtr handle,bool write,uint address,byte[] data) {
      if(address<0x82000000 || (ulong)address+(uint)data.Length>0x82800000 || data.Length<1 || data.Length>4096)
        throw new Exception("Bulk transfer outside fixed RAM window/block limit");
      // Reference WR/RD_LARGE_MEM uses a little-endian RAM address and byte count,
      // with xferNeedReply=0. This is not the storage DOWNLOAD protocol.
      byte[] header=new byte[16];BitConverter.GetBytes(address).CopyTo(header,0);BitConverter.GetBytes(data.Length).CopyTo(header,4);
      SetupPacket packet=new SetupPacket {Type=0x40,Request=(byte)(write?0x11:0x12),Value=(ushort)data.Length,Index=1,Length=16};uint count;
      Check(WinUsb_ControlTransfer(handle,packet,header,16,out count,IntPtr.Zero),"Set up RAM bulk transfer");
      if(count!=16)throw new Exception("Short bulk setup");
      bool ok=write?WinUsb_WritePipe(handle,2,data,(uint)data.Length,out count,IntPtr.Zero):WinUsb_ReadPipe(handle,0x81,data,(uint)data.Length,out count,IntPtr.Zero);
      Check(ok,"Bulk RAM 0x"+address.ToString("x8"));if(count!=data.Length)throw new Exception("Short RAM bulk transfer");return data;
    }
    public static RamResult Run(string action,byte[] image,string interfaceGuid,bool bulk) {
      if(action!="SelfTest" && action!="BulkTest" && action!="Status" && action!="Reset" && action!="UploadCandidate" && action!="BootCandidate" && action!="UploadAndBoot")throw new Exception("Unknown action");
      const string expected="f05adbc3d79c8f41be7fef1145f6111f436d35921b7051722ae5195ae7624bba";
      if(action=="UploadCandidate" || action=="BootCandidate" || action=="UploadAndBoot") {
        if(image==null || image.Length!=8388608 || Hash(image)!=expected)throw new Exception("Candidate hash/size mismatch before USB access");
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
          RamResult result=new RamResult {Found=true,DevicePath=path,VidPid="1B8E:C003",VendorRequestSent=false,InterfaceGuid=guid.ToString(),Action=action};
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
            uint timeout=3000; Check(WinUsb_SetPipePolicy(handle,0,3,4,ref timeout),"Set bounded control timeout");
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
            if(action=="BulkTest" && !Same(original,TransferBulk(handle,false,0x82000000,new byte[64])))throw new Exception("Bulk/control RAM read mismatch");
            byte[] pattern=new byte[64];for(int i=0;i<pattern.Length;i++)pattern[i]=(byte)(i^0xa5);
            try {
              if(action=="BulkTest")TransferBulk(handle,true,0x82000000,pattern);else Write(handle,0x82000000,pattern);
              result.PatternVerified=Same(pattern,Read(handle,0x82000000,64));
              if(!result.PatternVerified)throw new Exception("RAM pattern mismatch");
            } finally {
              Write(handle,0x82000000,original);
              result.OriginalRestored=Same(original,Read(handle,0x82000000,64));
              if(!result.OriginalRestored)throw new Exception("Original RAM bytes not restored");
            }
          }
          if(action=="UploadCandidate" || action=="BootCandidate" || action=="UploadAndBoot") {
            byte[] readback=new byte[image.Length];
            int block=bulk?4096:64;
            for(int offset=0;offset<image.Length;offset+=block) {
              if(action=="UploadCandidate" || action=="UploadAndBoot") {
                byte[] chunk=new byte[block];Buffer.BlockCopy(image,offset,chunk,0,block);
                if(bulk)TransferBulk(handle,true,0x82000000+(uint)offset,chunk);else Write(handle,0x82000000+(uint)offset,chunk);
              }
              byte[] actual=bulk?TransferBulk(handle,false,0x82000000+(uint)offset,new byte[block]):Read(handle,0x82000000+(uint)offset,block);
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
$image=$null
if($Action -in @('UploadCandidate','BootCandidate','UploadAndBoot')) {
    $candidate=Join-Path $PSScriptRoot '../target/mibox-boot-candidate/boot1-custom.NOT_READY.img'
    $image=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $candidate).Path)
}
foreach($guid in @($guids | Select-Object -Unique)) {
    $result=[MiboxLoader.RamTest]::Run($Action,$image,$guid,[bool]$Bulk)
    if($result.Found) {break}
}
$result | ConvertTo-Json
if(-not $result.Found) {throw 'Loader interface absent'}

# Bounded single-attempt bulk path probe for the C003 loader.
# Framing restored from reference source codesnake/uboot-amlogic commit
# c0b0b8cc9bd5901ced2e929ea87b99fae52d528c, drivers/usb/gadget/v2_burning/
# v2_usb_tool/usb_pcd.c do_vendor_out_complete AM_REQ_RD_LARGE_MEM branch:
#   1. EP0 SETUP 0x40/0x12, wValue=block len, wIndex=block count, wLength=16
#   2. EP0 OUT 16 bytes: [0..3]=address, [4..7]=total data length (LE)
#   3. Loader arms bulk IN (0x81); host reads exactly that many bytes.
# Safety rules:
#   - Exactly ONE bulk attempt per invocation; no in-script retry loop.
#   - Read-only: fixed address 0x82000000, 64 bytes (saved loadaddr region,
#     below the 512-byte EP0 scratch limit). No write, no boot command.
#   - Refuses unless identify reports 00-08-00-10 and the descriptor matches
#     the scoped device.
#   - A failed bulk attempt is terminal: record evidence, stop, and require an
#     owner power cycle. Never resend.
#   - The last step re-runs identify to record whether the loader survived.
param([string]$EvidenceRoot = (Join-Path $PSScriptRoot '..\artifacts\usb-loader-protocol'))
$ErrorActionPreference='Stop'
if(-not ('MiboxLoader.BulkProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;
namespace MiboxLoader {
  public sealed class BulkProbeResult {
    public bool Found; public string DevicePath; public string VidPid;
    public string IdentifyHex; public string ControlReadHex;
    public bool SetupSent; public uint SetupTransferred;
    public string BulkPipeInfo; public int BulkReadResult; public string BulkReadHex; public int BulkReadBytes;
    public string PostIdentifyHex; public bool PostIdentifyOk;
    public bool Match; public string Outcome; public string Error;
  }
  [StructLayout(LayoutKind.Sequential, Pack=1)] struct SetupPacket {
    public byte Type; public byte Request; public ushort Value; public ushort Index; public ushort Length;
  }
  [StructLayout(LayoutKind.Sequential)] struct USBPipeInfo {
    public uint PipeType; public byte EndpointAddress; public byte Interval;
    public uint MaxPacketSize; public byte PipeId;
  }
  public static class BulkProbe {
    [StructLayout(LayoutKind.Sequential)] struct InterfaceData {
      public uint Size; public Guid ClassGuid; public uint Flags; public IntPtr Reserved;
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
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_QueryPipe(IntPtr handle,byte interfaceIndex,byte pipeIndex,out USBPipeInfo info);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_SetPipePolicy(IntPtr handle,byte pipe,uint type,uint size,ref uint value);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_ReadPipe(IntPtr handle,byte pipe,byte[] data,uint size,out uint transferred,IntPtr overlapped);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_ControlTransfer(IntPtr handle,SetupPacket packet,byte[] data,uint size,out uint transferred,IntPtr overlapped);
    static void Check(bool ok,string operation) {
      if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error(),operation);
    }
    const uint PIPE_TRANSFER_TIMEOUT = 3;
    static string Hex(byte[] data,int length) {
      var builder=new System.Text.StringBuilder(length*3);
      for(int i=0;i<length;i++) builder.Append(data[i].ToString("x2")).Append('-');
      if(length>0) builder.Length--;
      return builder.ToString();
    }
    // Returns the result; never throws for bulk-stage failures: those are
    // evidence, and a thrown abort would skip the post-identify probe.
    public static BulkProbeResult Run(string interfaceGuid) {
      var result=new BulkProbeResult();
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
      if(path==null) { result.Found=false; result.Outcome="LOADER_ABSENT"; return result; }
      result.Found=true; result.DevicePath=path; result.VidPid="1B8E:C003";
      try {
        using(SafeFileHandle file=CreateFile(path,0xc0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero)) {
          if(file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"Open exact loader interface");
          IntPtr handle; Check(WinUsb_Initialize(file,out handle),"Initialize WinUSB");
          try {
            byte[] descriptor=new byte[18]; uint count;
            Check(WinUsb_GetDescriptorPtr(handle,1,0,0,descriptor,18,out count),"Read standard device descriptor");
            if(count!=18 || descriptor[0]!=18 || descriptor[1]!=1 || BitConverter.ToUInt16(descriptor,8)!=0x1b8e || BitConverter.ToUInt16(descriptor,10)!=0xc003)
              throw new Exception("Descriptor does not match scoped loader; no vendor request sent");
            // Step 0: identify, then a known-good control-channel read of the
            // target address as reference bytes (AM_REQ_READ_MEM 0x02).
            uint controlTimeout=3000; Check(WinUsb_SetPipePolicy(handle,0,PIPE_TRANSFER_TIMEOUT,4,ref controlTimeout),"Set control timeout");
            SetupPacket identify=new SetupPacket {Type=0xc0,Request=0x20,Value=0,Index=0,Length=4};
            byte[] id=new byte[4];
            Check(WinUsb_ControlTransfer(handle,identify,id,4,out count,IntPtr.Zero),"Read loader identification");
            if(count!=4) throw new Exception("Unexpected identify length");
            result.IdentifyHex=Hex(id,4);
            if(result.IdentifyHex!="00-08-00-10") throw new Exception("Unverified loader version; bulk probe refused");
            const uint address=0x82000000u;
            byte[] reference=new byte[64];
            SetupPacket read=new SetupPacket {Type=0xc0,Request=0x02,Value=0x8200,Index=0,Length=64};
            Check(WinUsb_ControlTransfer(handle,read,reference,64,out count,IntPtr.Zero),"Control read reference bytes");
            if(count!=64) throw new Exception("Unexpected control read length");
            result.ControlReadHex=Hex(reference,64);
            // Step 1: locate the bulk IN pipe for endpoint 0x81.
            int bulkPipe=-1; var pipeDump=new System.Text.StringBuilder();
            for(byte i=0;i<8;i++) {
              USBPipeInfo info;
              if(!WinUsb_QueryPipe(handle,0,i,out info)) break;
              pipeDump.Append("pipe").Append(i).Append(":ep0x").Append(info.EndpointAddress.ToString("x2"))
                      .Append(",type").Append(info.PipeType).Append(",mps").Append(info.MaxPacketSize).Append(';');
              if(info.PipeType!=3 && info.EndpointAddress==0x81) { bulkPipe=i; }
            }
            result.BulkPipeInfo=pipeDump.ToString();
            if(bulkPipe<0) { result.Outcome="NO_BULK_IN_PIPE"; result.Error=result.BulkPipeInfo; return result; }
            // Step 2: the single bounded bulk attempt.
            uint bulkTimeout=2000; Check(WinUsb_SetPipePolicy(handle,(byte)bulkPipe,PIPE_TRANSFER_TIMEOUT,4,ref bulkTimeout),"Set bulk timeout");
            SetupPacket large=new SetupPacket {Type=0x40,Request=0x12,Value=64,Index=1,Length=16};
            byte[] command=new byte[16];
            unchecked {
              command[0]=(byte)address; command[1]=(byte)(address>>8); command[2]=(byte)(address>>16); command[3]=(byte)(address>>24);
            }
            command[4]=64;
            try {
              Check(WinUsb_ControlTransfer(handle,large,command,16,out count,IntPtr.Zero),"EP0 RD_LARGE_MEM setup+data");
              if(count!=16) { result.Outcome="SETUP_SHORT"; result.Error="transferred "+count; return result; }
              result.SetupSent=true; result.SetupTransferred=count;
            } catch(Exception error) { result.Outcome="SETUP_FAILED"; result.Error=error.Message; return result; }
            // Step 3: read the armed bulk IN pipe, exactly 64 bytes expected.
            byte[] bulk=new byte[64];
            try {
              Check(WinUsb_ReadPipe(handle,(byte)bulkPipe,bulk,64,out count,IntPtr.Zero),"Bulk IN read");
              result.BulkReadResult=0; result.BulkReadBytes=(int)count; result.BulkReadHex=Hex(bulk,(int)count);
            } catch(Win32Exception error) {
              result.BulkReadResult=error.ErrorCode; result.Error="bulk read: "+error.Message+" (native "+error.NativeErrorCode+")";
              result.Outcome="BULK_TIMEOUT"; return result;
            } catch(Exception error) {
              result.BulkReadResult=-1; result.Error="bulk read: "+error.Message;
              result.Outcome="BULK_FAILED"; return result;
            }
            result.Match=(count==64) && CompareHex(result.BulkReadHex,result.ControlReadHex);
            result.Outcome=result.Match?"BULK_MATCH":"BULK_MISMATCH";
            return result;
          } finally {WinUsb_Free(handle);}
        }
      } finally {
        // Step 4: re-identify after everything, on a fresh handle, to record
        // whether the loader state machine survived. Failure here is itself
        // evidence (wedged loader -> owner power cycle required).
        try {
          using(SafeFileHandle file=CreateFile(path,0xc0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero)) {
            if(file.IsInvalid) { result.PostIdentifyOk=false; }
            else {
            IntPtr handle;
            if(!WinUsb_Initialize(file,out handle)) { result.PostIdentifyOk=false; }
            else {
              byte[] id=new byte[4]; uint count;
              SetupPacket identify=new SetupPacket {Type=0xc0,Request=0x20,Value=0,Index=0,Length=4};
              uint timeout=3000; WinUsb_SetPipePolicy(handle,0,PIPE_TRANSFER_TIMEOUT,4,ref timeout);
              if(WinUsb_ControlTransfer(handle,identify,id,4,out count,IntPtr.Zero) && count==4) {
                result.PostIdentifyOk=true; result.PostIdentifyHex=Hex(id,4);
              } else result.PostIdentifyOk=false;
              WinUsb_Free(handle);
            }
            }
          }
        } catch { result.PostIdentifyOk=false; }
      }
    }
    static bool CompareHex(string a,string b) { return string.Equals(a,b,StringComparison.Ordinal); }
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_GetDescriptor(IntPtr handle,byte type,byte index,ushort language,byte[] data,uint size,out uint transferred);
    // Alias keeps the shared call sites uniform.
    static bool WinUsb_GetDescriptorPtr(IntPtr h,byte t,byte i,ushort l,byte[] d,uint s,out uint tr) { return WinUsb_GetDescriptor(h,t,i,l,d,s,out tr); }
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
foreach($guid in @($guids | Select-Object -Unique)) {
    $result=[MiboxLoader.BulkProbe]::Run($guid)
    if($result.Found) {break}
}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$directory=Join-Path $EvidenceRoot "bulk-$stamp"
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$report=[ordered]@{
    timestamp_utc=(Get-Date).ToUniversalTime().ToString('o')
    framing='reference codesnake/uboot-amlogic c0b0b8cc usb_pcd.c AM_REQ_RD_LARGE_MEM'
    address='0x82000000'; length=64; attempts=1; retry_policy='none; failure requires owner power cycle'
    result=$result
}
$json=$report | ConvertTo-Json -Depth 6
$encoding=New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $directory 'bulk-probe.json'),$json,$encoding)
if($result.ControlReadHex) {[IO.File]::WriteAllText((Join-Path $directory 'control-reference.hex'),$result.ControlReadHex,$encoding)}
if($result.BulkReadHex) {[IO.File]::WriteAllText((Join-Path $directory 'bulk-read.hex'),$result.BulkReadHex,$encoding)}
$result | ConvertTo-Json -Depth 4
if(-not $result.Found) {throw 'Loader interface absent: enter confirmed loader mode and install the scoped WinUSB preset first'}
if($result.Outcome -in @('BULK_TIMEOUT','BULK_FAILED','SETUP_FAILED') -and -not $result.PostIdentifyOk) {
    throw 'Loader did not answer post-probe identify: STOP. Do not retry; owner power cycle required. Evidence retained.'
}

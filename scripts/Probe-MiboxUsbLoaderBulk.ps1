# Bounded single-attempt bulk path probe for the C003 loader.
# Framing from reference source codesnake/uboot-amlogic commit
# c0b0b8cc9bd5901ced2e929ea87b99fae52d528c, drivers/usb/gadget/v2_burning/
# v2_usb_tool/usb_pcd.c do_vendor_out_complete AM_REQ_WR/RD_LARGE_MEM branch:
#   1. EP0 SETUP 0x40/0x11 (write) or 0x12 (read), wValue=block len,
#      wIndex=block count, wLength=16 (the loader recomputes both from data)
#   2. EP0 OUT 16 bytes: [0..3]=address, [4..7]=total data length (LE)
#   3. Loader arms bulk OUT 0x02 (write) or bulk IN 0x81 (read).
#
# WinUSB pipe policy and ReadPipe/WritePipe take the ENDPOINT ADDRESS
# (0x81 / 0x02) as PipeID, not the WinUsb_QueryPipe index. The 2026-11-15
# attempt passed index 0 and failed host-side with native 87 before any IN
# token reached the device; the loader was left with an armed, undrained bulk
# IN request, which in the DWC non-periodic TX FIFO blocks later EP0 IN
# replies (identify). That result therefore says nothing about the device.
#
# Direction Write (default): bulk OUT carries a XOR pattern into the fixed
# boot buffer, the established 64-byte EP0 READ_MEM channel verifies it, and
# the original bytes are restored over EP0 and verified. Bulk OUT data lands in
# the RX FIFO path that EP0 OUT already uses successfully.
# Direction Read: one bulk IN read of 64 bytes, compared with an EP0 read.
#
# Safety rules:
#   - Exactly ONE bulk attempt per invocation; no in-script retry loop.
#   - Fixed address 0x82000000 (saved loadaddr region); 64 or 4096 bytes.
#   - Refuses unless identify reports 00-08-00-10 and the descriptor matches.
#   - A failed bulk attempt is terminal: record evidence and stop. If the
#     post-probe identify does not answer, the owner must power cycle.
#   - The last step re-runs identify on a fresh handle to record survival.
param(
    [ValidateSet('Write','Read')][string]$Direction='Write',
    [ValidateSet(64,4096)][int]$Bytes=64,
    [string]$EvidenceRoot = (Join-Path $PSScriptRoot '..\artifacts\usb-loader-protocol')
)
$ErrorActionPreference='Stop'
if($Direction -eq 'Read' -and $Bytes -ne 64) {throw 'Bulk read probe is limited to 64 bytes'}
if(-not ('MiboxLoader.BulkProbe2' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;
namespace MiboxLoader {
  public sealed class BulkProbeResult2 {
    public bool Found; public string DevicePath; public string VidPid; public string Direction; public int Bytes;
    public string IdentifyHex; public string ControlReadHex;
    public bool SetupSent; public uint SetupTransferred;
    public string BulkPipeInfo; public int BulkNativeError; public string BulkReadHex; public int BulkBytes;
    public double BulkMilliseconds;
    public bool PatternVerified; public bool OriginalRestored;
    public string PostIdentifyHex; public bool PostIdentifyOk;
    public bool Match; public string Outcome; public string Error;
  }
  [StructLayout(LayoutKind.Sequential, Pack=1)] struct SetupPacket2 {
    public byte Type; public byte Request; public ushort Value; public ushort Index; public ushort Length;
  }
  // WINUSB_PIPE_INFORMATION: USBD_PIPE_TYPE PipeType; UCHAR PipeId;
  // USHORT MaximumPacketSize; UCHAR Interval (natural alignment, 12 bytes).
  [StructLayout(LayoutKind.Sequential)] struct PipeInfo2 {
    public int PipeType; public byte PipeId; public ushort MaximumPacketSize; public byte Interval;
  }
  public static class BulkProbe2 {
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
    static extern bool WinUsb_QueryPipe(IntPtr handle,byte alternate,byte pipeIndex,out PipeInfo2 info);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_SetPipePolicy(IntPtr handle,byte pipeId,uint type,uint size,ref uint value);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_ReadPipe(IntPtr handle,byte pipeId,byte[] data,uint size,out uint transferred,IntPtr overlapped);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_WritePipe(IntPtr handle,byte pipeId,byte[] data,uint size,out uint transferred,IntPtr overlapped);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_ControlTransfer(IntPtr handle,SetupPacket2 packet,byte[] data,uint size,out uint transferred,IntPtr overlapped);
    [DllImport("winusb.dll",SetLastError=true)]
    static extern bool WinUsb_GetDescriptor(IntPtr handle,byte type,byte index,ushort language,byte[] data,uint size,out uint transferred);
    const uint PIPE_TRANSFER_TIMEOUT = 3;
    const byte BULK_IN = 0x81, BULK_OUT = 0x02;
    const uint BASE = 0x82000000u;
    static void Check(bool ok,string operation) {
      if(!ok) { int error=Marshal.GetLastWin32Error(); throw new Win32Exception(error,operation+" (Win32 "+error+")"); }
    }
    static string Hex(byte[] data,int length) {
      var builder=new System.Text.StringBuilder(length*3);
      for(int i=0;i<length;i++) builder.Append(data[i].ToString("x2")).Append('-');
      if(length>0) builder.Length--;
      return builder.ToString();
    }
    static bool Same(byte[] a,byte[] b) {
      if(a.Length!=b.Length) return false;
      for(int i=0;i<a.Length;i++) if(a[i]!=b[i]) return false;
      return true;
    }
    // Established EP0 channel: 64-byte READ_MEM 0x02 / WRITE_MEM 0x01.
    static byte[] ControlRead(IntPtr handle,uint address,int length) {
      byte[] all=new byte[length];
      for(int offset=0;offset<length;offset+=64) {
        uint at=address+(uint)offset; byte[] part=new byte[64]; uint count;
        SetupPacket2 packet=new SetupPacket2 {Type=0xc0,Request=0x02,Value=(ushort)(at>>16),Index=(ushort)(at&0xffff),Length=64};
        Check(WinUsb_ControlTransfer(handle,packet,part,64,out count,IntPtr.Zero),"Control read 0x"+at.ToString("x8"));
        if(count!=64) throw new Exception("Short control read");
        Buffer.BlockCopy(part,0,all,offset,64);
      }
      return all;
    }
    static void ControlWrite(IntPtr handle,uint address,byte[] data) {
      for(int offset=0;offset<data.Length;offset+=64) {
        uint at=address+(uint)offset; byte[] part=new byte[64]; uint count;
        Buffer.BlockCopy(data,offset,part,0,64);
        SetupPacket2 packet=new SetupPacket2 {Type=0x40,Request=0x01,Value=(ushort)(at>>16),Index=(ushort)(at&0xffff),Length=64};
        Check(WinUsb_ControlTransfer(handle,packet,part,64,out count,IntPtr.Zero),"Control write 0x"+at.ToString("x8"));
        if(count!=64) throw new Exception("Short control write");
      }
    }
    static string FindPath(string interfaceGuid) {
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
      return path;
    }
    public static BulkProbeResult2 Run(string interfaceGuid,bool write,int bytes) {
      if(bytes!=64 && bytes!=4096) throw new Exception("Probe size must be 64 or 4096");
      if(!write && bytes!=64) throw new Exception("Bulk read probe is limited to 64 bytes");
      var result=new BulkProbeResult2 {Direction=write?"Write":"Read",Bytes=bytes};
      string path=FindPath(interfaceGuid);
      if(path==null) { result.Found=false; result.Outcome="LOADER_ABSENT"; return result; }
      result.Found=true; result.DevicePath=path; result.VidPid="1B8E:C003";
      try {
        using(SafeFileHandle file=CreateFile(path,0xc0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero)) {
          if(file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"Open exact loader interface");
          IntPtr handle; Check(WinUsb_Initialize(file,out handle),"Initialize WinUSB");
          try {
            byte[] descriptor=new byte[18]; uint count;
            Check(WinUsb_GetDescriptor(handle,1,0,0,descriptor,18,out count),"Read standard device descriptor");
            if(count!=18 || descriptor[0]!=18 || descriptor[1]!=1 || BitConverter.ToUInt16(descriptor,8)!=0x1b8e || BitConverter.ToUInt16(descriptor,10)!=0xc003)
              throw new Exception("Descriptor does not match scoped loader; no vendor request sent");
            uint controlTimeout=3000; Check(WinUsb_SetPipePolicy(handle,0,PIPE_TRANSFER_TIMEOUT,4,ref controlTimeout),"Set control timeout");
            SetupPacket2 identify=new SetupPacket2 {Type=0xc0,Request=0x20,Value=0,Index=0,Length=4};
            byte[] id=new byte[4];
            Check(WinUsb_ControlTransfer(handle,identify,id,4,out count,IntPtr.Zero),"Read loader identification");
            if(count!=4) throw new Exception("Unexpected identify length");
            result.IdentifyHex=Hex(id,4);
            if(result.IdentifyHex!="00-08-00-10") throw new Exception("Unverified loader version; bulk probe refused");
            byte[] original=ControlRead(handle,BASE,bytes);
            result.ControlReadHex=Hex(original,Math.Min(64,bytes));
            // Endpoint inventory with the correct struct; policy uses PipeId.
            bool haveIn=false,haveOut=false; var dump=new System.Text.StringBuilder();
            for(byte i=0;i<8;i++) {
              PipeInfo2 info;
              if(!WinUsb_QueryPipe(handle,0,i,out info)) break;
              dump.Append("pipe").Append(i).Append(":ep0x").Append(info.PipeId.ToString("x2"))
                  .Append(",type").Append(info.PipeType).Append(",mps").Append(info.MaximumPacketSize).Append(';');
              if(info.PipeType==2 && info.PipeId==BULK_IN && info.MaximumPacketSize==512) haveIn=true;
              if(info.PipeType==2 && info.PipeId==BULK_OUT && info.MaximumPacketSize==512) haveOut=true;
            }
            result.BulkPipeInfo=dump.ToString();
            if(!haveIn || !haveOut) { result.Outcome="BULK_PIPES_UNEXPECTED"; result.Error=result.BulkPipeInfo; return result; }
            byte pipe=write?BULK_OUT:BULK_IN;
            uint bulkTimeout=2000; Check(WinUsb_SetPipePolicy(handle,pipe,PIPE_TRANSFER_TIMEOUT,4,ref bulkTimeout),"Set bulk timeout");
            byte[] pattern=new byte[bytes];
            for(int i=0;i<bytes;i++) pattern[i]=(byte)(original[i]^0xa5^(i>>6));
            // The single bounded bulk attempt.
            byte[] command=new byte[16];
            BitConverter.GetBytes(BASE).CopyTo(command,0); BitConverter.GetBytes((uint)bytes).CopyTo(command,4);
            SetupPacket2 large=new SetupPacket2 {Type=0x40,Request=(byte)(write?0x11:0x12),
              Value=(ushort)Math.Min(bytes,4096),Index=1,Length=16};
            try {
              Check(WinUsb_ControlTransfer(handle,large,command,16,out count,IntPtr.Zero),"EP0 LARGE_MEM setup+data");
              if(count!=16) { result.Outcome="SETUP_SHORT"; result.Error="transferred "+count; return result; }
              result.SetupSent=true; result.SetupTransferred=count;
            } catch(Exception error) { result.Outcome="SETUP_FAILED"; result.Error=error.Message; return result; }
            var clock=System.Diagnostics.Stopwatch.StartNew();
            byte[] bulk=write?pattern:new byte[bytes];
            bool ok=write?WinUsb_WritePipe(handle,pipe,bulk,(uint)bytes,out count,IntPtr.Zero)
                         :WinUsb_ReadPipe(handle,pipe,bulk,(uint)bytes,out count,IntPtr.Zero);
            result.BulkMilliseconds=clock.Elapsed.TotalMilliseconds;
            if(!ok) {
              result.BulkNativeError=Marshal.GetLastWin32Error();
              result.Error="bulk "+(write?"OUT write":"IN read")+" failed (Win32 "+result.BulkNativeError+")";
              result.Outcome=result.BulkNativeError==121?"BULK_TIMEOUT":"BULK_FAILED"; return result;
            }
            result.BulkBytes=(int)count;
            if(count!=bytes) { result.Outcome="BULK_SHORT"; result.Error="transferred "+count; return result; }
            if(!write) {
              result.BulkReadHex=Hex(bulk,(int)count);
              result.Match=Same(bulk,original);
              result.Outcome=result.Match?"BULK_MATCH":"BULK_MISMATCH";
              return result;
            }
            // Write: verify over EP0, then restore original bytes and verify.
            try {
              result.PatternVerified=Same(pattern,ControlRead(handle,BASE,bytes));
            } finally {
              ControlWrite(handle,BASE,original);
              result.OriginalRestored=Same(original,ControlRead(handle,BASE,bytes));
            }
            result.Match=result.PatternVerified && result.OriginalRestored;
            result.Outcome=result.PatternVerified?(result.OriginalRestored?"BULK_WRITE_VERIFIED":"RESTORE_FAILED"):"BULK_WRITE_MISMATCH";
            return result;
          } finally {WinUsb_Free(handle);}
        }
      } catch(Exception error) {
        if(result.Outcome==null) { result.Outcome="HOST_ERROR"; result.Error=error.Message; }
        return result;
      } finally {
        // Fresh-handle identify records whether the loader survived.
        try {
          using(SafeFileHandle file=CreateFile(path,0xc0000000,3,IntPtr.Zero,3,0x40000000,IntPtr.Zero)) {
            IntPtr handle;
            if(!file.IsInvalid && WinUsb_Initialize(file,out handle)) {
              byte[] id=new byte[4]; uint count;
              SetupPacket2 identify=new SetupPacket2 {Type=0xc0,Request=0x20,Value=0,Index=0,Length=4};
              uint timeout=3000; WinUsb_SetPipePolicy(handle,0,PIPE_TRANSFER_TIMEOUT,4,ref timeout);
              if(WinUsb_ControlTransfer(handle,identify,id,4,out count,IntPtr.Zero) && count==4) {
                result.PostIdentifyOk=true; result.PostIdentifyHex=Hex(id,4);
              }
              WinUsb_Free(handle);
            }
          }
        } catch { result.PostIdentifyOk=false; }
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
foreach($guid in @($guids | Select-Object -Unique)) {
    $result=[MiboxLoader.BulkProbe2]::Run($guid,$Direction -eq 'Write',$Bytes)
    if($result.Found) {break}
}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$directory=Join-Path $EvidenceRoot "bulk-$stamp"
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$report=[ordered]@{
    timestamp_utc=(Get-Date).ToUniversalTime().ToString('o')
    framing='reference codesnake/uboot-amlogic c0b0b8cc usb_pcd.c AM_REQ_WR/RD_LARGE_MEM; PipeId = endpoint address'
    direction=$Direction; address='0x82000000'; length=$Bytes; attempts=1
    retry_policy='none; failure without post-identify requires owner power cycle'
    result=$result
}
$encoding=New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $directory 'bulk-probe.json'),($report | ConvertTo-Json -Depth 6),$encoding)
$result | ConvertTo-Json -Depth 4
if(-not $result.Found) {throw 'Loader interface absent: enter confirmed loader mode first'}
if(-not $result.PostIdentifyOk) {
    throw 'Loader did not answer post-probe identify: STOP. Do not retry; owner power cycle required. Evidence retained.'
}

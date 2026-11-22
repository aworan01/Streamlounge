import Foundation
import Network
import Combine
import UIKit
import Darwin

/// Opt-in one-session LAN importer. The browser sends raw M3U bytes in a POST
/// body; no credentials, playlist data or channel URLs leave the local network.
@MainActor final class LocalM3UServer: ObservableObject {
    @Published private(set) var address = ""
    @Published private(set) var status = "Not running"
    @Published private(set) var pin = ""
    @Published private(set) var running = false
    private var listener: NWListener?
    private let port: UInt16 = 8877
        var onM3U: ((String)->Void)?

    func start() {
        guard listener == nil else {return}
        do {
            let server=try NWListener(using:.tcp,on:NWEndpoint.Port(rawValue:port)!)
            pin=String(format:"%06d",Int.random(in:100000...999999))
            server.newConnectionHandler = { [weak self] conn in
                conn.start(queue:.global(qos:.utility))
                Task { @MainActor in self?.accept(conn) }
            }
            server.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.running=true; self?.address="http://"+(Self.lanAddress() ?? "APPLE-TV-IP")+":8877";self?.status="Open on a device connected to the same Wi-Fi"
                    case .failed(let e):self?.stop();self?.status="Transfer server error: \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            listener=server
            server.start(queue:.global(qos:.utility))
        } catch {status="Could not open local transfer port: \(error.localizedDescription)"}
    }
    func stop() {
        listener?.cancel();listener=nil;running=false;pin="";address="";status="Not running"
    }
    private func accept(_ conn:NWConnection) {
        receive(conn,bytes:Data())
    }
    private nonisolated func receive(_ conn:NWConnection, bytes:Data) {
        conn.receive(minimumIncompleteLength:1,maximumLength:64*1024) { [weak self] chunk,_,complete,error in
            guard let self=self else {conn.cancel();return}
            var accumulated=bytes
            if let chunk=chunk {accumulated.append(chunk)}
            if accumulated.count > 9*1024*1024 {self.reply(conn,status:413,body:"File too large");return}
            guard let range=accumulated.range(of:Data("\r\n\r\n".utf8)) else {
                if complete || error != nil {conn.cancel()} else {self.receive(conn,bytes:accumulated)}
                return
            }
            let header=String(decoding:accumulated[..<range.lowerBound],as:UTF8.self)
            let headers=header.components(separatedBy:"\r\n")
            let path=headers.first ?? ""
            let size=headers.first(where:{$0.lowercased().hasPrefix("content-length:")}).flatMap {Int($0.split(separator:":",maxSplits:1).last?.trimmingCharacters(in:.whitespaces) ?? "")} ?? 0
            let body=accumulated[range.upperBound...]
            if path.hasPrefix("GET /") {
                Task { @MainActor in
                    let pin=self.pin
                    self.reply(conn,status:200,body:Self.page(pin:pin),contentType:"text/html; charset=utf-8")
                }
                return
            }
            guard path.hasPrefix("POST /import") else {self.reply(conn,status:404,body:"Not found");return}
            guard size>0 && size<=8*1024*1024 else {self.reply(conn,status:413,body:"Invalid file size");return}
            guard body.count >= size else {
                if complete || error != nil {conn.cancel()} else {self.receive(conn,bytes:accumulated)}
                return
            }
            let sentPIN=headers.first(where:{$0.lowercased().hasPrefix("x-transfer-pin:")}).map{$0.split(separator:":",maxSplits:1).last?.trimmingCharacters(in:.whitespaces) ?? ""} ?? ""
            let payload=Data(body.prefix(size))
            Task { @MainActor in
                guard self.running, sentPIN == self.pin else {self.reply(conn,status:403,body:"Incorrect transfer PIN");return}
                guard let text=String(data:payload,encoding:.utf8) ?? String(data:payload,encoding:.isoLatin1),text.contains("#EXTM3U") else {self.reply(conn,status:400,body:"Not an M3U playlist");return}
                self.onM3U?(text)
                self.status="Playlist received. Processing…"
                self.reply(conn,status:200,body:"Playlist received. You can return to Apple TV.")
                self.stop()
            }
        }
    }
    private nonisolated func reply(_ conn:NWConnection,status:Int,body:String,contentType:String="text/plain; charset=utf-8") {
        let data=Data(body.utf8)
        let response="HTTP/1.1 \(status) \(status==200 ? "OK" : "Error")\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        conn.send(content:Data(response.utf8)+data,completion:.contentProcessed{_ in conn.cancel()})
    }
    private static func page(pin:String)->String {"""
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Stream Lounge TV local import</title><style>body{font:17px system-ui;background:#131b29;color:#fff;max-width:560px;margin:55px auto;padding:18px}input,button{font:inherit;padding:12px;margin:12px 0;width:100%}button{background:#67e8f9;color:#101722;border:0;border-radius:8px}</style>
    <h1>Stream Lounge TV</h1><p>Choose an M3U file on this device. Your data goes directly to your Apple TV on your local network.</p>
    <p>Enter the six-digit PIN displayed on the TV:</p><input id="pin" inputmode="numeric" maxlength="6" autocomplete="off" placeholder="Transfer PIN">
    <input id="file" type="file" accept=".m3u,.m3u8,text/plain"><button onclick="send()">Send playlist</button><p id="status"></p>
    <script>async function send(){const f=document.getElementById('file').files[0],p=document.getElementById('pin').value,s=document.getElementById('status');if(!f||p.length!=6){s.textContent='Choose a file and enter the six-digit PIN';return;}try{const r=await fetch('/import',{method:'POST',headers:{'X-Transfer-PIN':p,'Content-Type':'text/plain'},body:f});s.textContent=await r.text()}catch(e){s.textContent=String(e)}}</script>
    </html>
    """}
    // The IP may not be directly available on all tvOS network configurations;
    // APPLE-TV-IP is shown as a placeholder rather than guessing an address.
    private static func lanAddress()->String? {
        var found:String?=nil
        var ptr:UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0,let first=ptr else{return nil}
        defer{freeifaddrs(ptr)}
        var next:UnsafeMutablePointer<ifaddrs>?=first
        while let node=next {
            let i=node.pointee
            if let a=i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) {
                var host=[CChar](repeating:0,count:Int(NI_MAXHOST))
                let rc=getnameinfo(a,socklen_t(a.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST)
                if rc == 0 {
                    let name=String(cString:host)
                    if !name.hasPrefix("127.") && !name.hasPrefix("169.254.") {found=name;break}
                }
            }
            next=i.ifa_next
        }
        return found
    }
}

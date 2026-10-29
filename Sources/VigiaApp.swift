import SwiftUI
import AppKit

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    static weak var state:AppState?
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        guard let state=Self.state else{return .terminateNow}
        let active=state.jobs.contains{$0.running}
        if active{
            let alert=NSAlert();alert.messageText="Finalizar gravações e sair?";alert.informativeText="Os arquivos precisam ser finalizados para que possam ser reproduzidos.";alert.addButton(withTitle:"Finalizar e sair");alert.addButton(withTitle:"Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else{return .terminateCancel}
            state.stopAll()
            Task{
                for _ in 0..<80{if !state.jobs.contains(where:{$0.running}){NSApp.reply(toApplicationShouldTerminate:true);return};try? await Task.sleep(nanoseconds:100_000_000)}
                let alert=NSAlert();alert.messageText="Ainda há gravações sendo finalizadas";alert.informativeText="Aguarde mais um pouco e tente sair novamente para preservar os arquivos.";alert.runModal();NSApp.reply(toApplicationShouldTerminate:false)
            }
            return .terminateLater
        }
        state.stopAll();return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
}
@main struct VigiaApp:App{
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state=AppState()
    var body:some Scene{
        WindowGroup("Vigia ARM"){
            RootView().environmentObject(state).onAppear{AppDelegate.state=state}
        }.defaultSize(width:1280,height:820).commands{
            CommandGroup(replacing:.newItem){Button("Novo equipamento…"){NotificationCenter.default.post(name:Notification.Name("VigiaNewCamera"),object:nil)}.keyboardShortcut("n");Button("Importar configuração…"){NotificationCenter.default.post(name:Notification.Name("VigiaImport"),object:nil)}.keyboardShortcut("i",modifiers:[.command,.shift])}
            CommandGroup(after:.saveItem){Button("Exportar configuração…"){state.exportConfiguration()}.keyboardShortcut("e",modifiers:[.command,.shift]);Button("Abrir vídeo local…"){state.openLocalRecording()}.keyboardShortcut("o")}
        }
    }
}

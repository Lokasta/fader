# Fader

Volume por app no macOS, direto da barra de menu. Sem driver, sem BlackHole, sem dispositivo virtual.

![Painel do Fader](docs/panel.png)

## O que faz

- **Volume de cada app** de 0 a 200%: baixa o Discord sem baixar o jogo, dá um boost num vídeo baixinho. Acima de 100% um limitador suave evita estourar.
- **Mudo por app** com um clique no alto-falante.
- **Lembra o volume** de cada app e reaplica sozinho quando ele volta a tocar.
- **Saída e microfone**: troca o dispositivo padrão e ajusta o volume de cada um (o mesmo que Ajustes > Som faz).
- Agrupa processos auxiliares no app certo: o áudio do Chrome, do Safari (WebKit) ou de um `afplay` no terminal aparece com o nome e o ícone do app dono.
- **Controle na Central de Controle** (macOS 26+): um botão "Fader" que abre o painel no canto da tela, igual à Central de Controle. Também pode ir direto pra barra de menu.
- Abre ao iniciar o Mac (dá pra desligar na engrenagem).

## Central de Controle

1. Abra a Central de Controle e clique em **Editar Controles**.
2. Busque **Fader** e arraste o controle pra Central de Controle ou pra barra de menu.

A Apple só permite **botões e liga/desliga** em controles de terceiros (o slider de Som é exclusivo do sistema), então o controle do Fader abre o painel completo com um clique. Por baixo ele chama `fader://panel`, que também funciona em atalhos, Raycast etc.

## Como funciona

Usa os **Core Audio Process Taps** (macOS 14.2+). Para cada app que não está em 100%:

1. Um *process tap* captura o áudio dos processos do app e, com `mutedWhenTapped`, impede que ele chegue direto nos alto-falantes.
2. Um dispositivo agregado privado junta esse tap com a saída atual.
3. Um IO proc copia as amostras do tap para a saída aplicando o ganho, com rampa por buffer (sem cliques).

Apps em 100% não passam por nada disso: o áudio deles segue o caminho normal do macOS.

### O microfone fica intocado

- O Fader **nunca abre um stream de entrada**. A bolinha laranja de microfone não acende por causa dele.
- Quando a saída é um fone Bluetooth (AirPods), o agregado também expõe o microfone do fone. O Fader desliga esses streams no IO proc (`kAudioDevicePropertyIOProcStreamUsage`), então o fone não cai no modo de chamada.
- O controle de microfone só muda o dispositivo padrão e o volume de entrada, que são propriedades do sistema.
- Se o Fader fechar ou travar, o macOS destrói os taps junto com o processo e o som volta ao normal na hora.

## Permissão

Na primeira vez o macOS pede **Gravação de Áudio do Sistema** (Ajustes > Privacidade e Segurança). Sem ela o Fader não cria taps, porque um tap sem permissão silenciaria o app.

## Desenvolvimento

Requer Xcode 26+ e [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./scripts/install.sh          # build Release, instala em /Applications e abre
xcodegen generate             # gera Fader.xcodeproj a partir do project.yml
xcodebuild -project Fader.xcodeproj -scheme Fader -derivedDataPath build test
swift scripts/make-icon.swift # regenera o ícone

# Renderiza o painel num PNG (útil para checar layout sem clicar na barra)
build/Build/Products/Debug/Fader.app/Contents/MacOS/Fader --snapshot painel.png

# Logs
/usr/bin/log show --last 5m --predicate 'subsystem == "com.lokasta.fader"' --info
```

## Abrindo o painel

- Ícone na barra de menu (ao lado do Som), controle da Central de Controle, atalho **⌃⌥V** de qualquer app, ou abrir o Fader de novo pelo Spotlight.
- Barra lotada (notch) esconde ícones sem aviso. Para fixar o Fader perto do relógio:
  `pkill -x Fader; defaults write com.lokasta.fader "NSStatusItem Preferred Position Item-0" -float 330; open -a Fader`
  (o número é a distância da borda direita; o Som da Apple fica por volta de 320).

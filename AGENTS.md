# QCY H3 Control — guia para assistentes de IA

App nativo de barra de menus para macOS que controla o headset **QCY H3 / H3 Pro**
pelo protocolo **JieLi RCSP** sobre Bluetooth Low Energy (BLE), sem o app oficial
da QCY.

Este arquivo vale para **qualquer** assistente de código (Claude Code, Codex,
Cursor, Gemini CLI, etc.). Siga na ordem e **não invente** nada de hardware: se
não souber, diga e verifique.

## 1. Requisitos

Confirme antes de qualquer coisa:

```sh
sw_vers -productVersion    # precisa ser macOS 14 ou superior
swift --version            # precisa de Swift 6 / Xcode Command Line Tools
```

Se faltar o Swift: `xcode-select --install`.

## 2. Compilar e rodar

```sh
./build.sh                 # compila (release) e monta "QCY H3 Control.app"
open "QCY H3 Control.app"
```

Para desenvolvimento, `swift run` funciona (o app é um agente, sem Dock).

## 3. Primeira execução: permissão de Bluetooth

O app usa CoreBluetooth, e o macOS exige consentimento do usuário
(`kTCCServiceBluetoothAlways`). Na primeira vez aparece um diálogo, e o texto dele
vem de `NSBluetoothAlwaysUsageDescription` no `Support/Info.plist`.

Atenção importante: o `build.sh` assina em modo **ad-hoc** (`codesign --sign -`).
Nesse modo o requisito designado fica preso ao hash do binário (cdhash), então
**cada rebuild invalida a permissão e o macOS pede de novo**. Isso é esperado, não
é bug. A solução, se o usuário quiser, é assinar com um certificado estável (um
autoassinado no login keychain já basta). Não troque o esquema de assinatura sem
perguntar.

## 4. Achar o fone

- No macOS o CoreBluetooth **não expõe o MAC**. Usa-se o `peripheral.identifier`
  (um UUID por-host). O MAC que aparece em `system_profiler` / `blueutil` **não
  serve**.
- O canal de controle aparece no scan como **`QCY H3 Pro-APP`**, no serviço GATT
  `0000a002-...` (write `00000001-...`, notify `00000002-...`).
- O app guarda o identificador do último fone em `UserDefaults`
  (`QCYPeripheralIdentifier`) para reconectar em menos de um segundo.
- A conexão é automática: o app procura o fone ao iniciar e reconecta se cair.
  Não existe botão "Conectar" (há um toggle "Conectar automaticamente" no menu ...).

## 5. Diagnóstico (testar sem clicar em nada)

```sh
BIN="./QCY H3 Control.app/Contents/MacOS/QCYMenubar"
"$BIN" --help
"$BIN" --diagnose                 # conecta e imprime bateria / ANC / game mode / EQ
"$BIN" --diagnose --write-test    # re-aplica os valores atuais (não muda nada)
```

O log do app fica em `~/Library/Application Support/QCYMenubar/log.txt`.

Observação: rodando o binário pelo Terminal, o pedido de Bluetooth pode ser
atribuído ao **Terminal** em vez do app (identidade diferente). Isso é normal.

## 6. Compatibilidade

- **Testado no QCY H3 Pro.** Os opcodes e as tabelas de ANC/EQ estão em
  `Sources/QCYMenubar/RCSP.swift`, que é a fonte única da verdade do protocolo.
- **Outros modelos QCY podem funcionar, mas não há garantia.** O app fala o
  JieLi RCSP no serviço `a002`. Se o fone expuser esse serviço com o mesmo layout e
  os mesmos comandos, deve funcionar. Modelos que usam o protocolo padrão da QCY
  (serviço `1001`/`1002`) ou chipset Airoha/ZR **não** funcionam.
- Nunca afirme que um modelo funciona sem testar. Use `--diagnose` nele e reporte
  a saída bruta.

## 7. Regras

- Não invente fato de hardware, versão, API ou comportamento. Se não sabe, diga e
  verifique na documentação ou no próprio fone.
- Ao mexer no protocolo, mantenha `RCSP.swift` como fonte única dos opcodes e
  tabelas.
- Não comite segredos, endereços de dispositivo, chaves ou dados pessoais.
- Não faça push, release ou publicação sem o usuário pedir explicitamente.
- O código é original. Não copie código dos projetos citados no
  `THIRD_PARTY_NOTICES.md`.
- Não há comando de desligar o fone por software nesse protocolo; só reiniciar
  (opcode `0xE7`). Para desligar, o usuário usa o botão do fone.

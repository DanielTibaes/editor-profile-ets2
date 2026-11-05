# Editor de Perfil - Euro Truck Simulator 2

Script em PowerShell que cria um perfil novo do ETS2 com XP, dinheiro, garagens, habilidades e outros itens já alterados. Você escolhe tudo em um menu no terminal.

O script sempre trabalha em uma **cópia**. O perfil original não é modificado.

## O que dá para alterar

| Opção | O que faz |
|---|---|
| **1 - XP** | Define o nível em % (0 a 100, onde 50% = nível 50) |
| **2 - Cash** | Soma 500 mil, 1, 5, 10 ou 30 milhões ao saldo atual |
| **3 - Garagens, concessionárias e agências** | Compra as garagens das cidades do seu mapa no tamanho máximo (5 vagas) e libera concessionárias e agências de recrutamento |
| **4 - Habilidades** | Coloca todas no máximo; opcionalmente, também as dos motoristas contratados |
| **5 - Mapa** | Marca todas as cidades como visitadas e descobre todas as empresas |
| **6 - Banco** | Quita os empréstimos, sem descontar do saldo, e sai do cheque especial |
| **7 - Frota** | Repara e abastece seus caminhões e reboques (o desgaste permanente não muda) |
| **8 - Todas** | Aplica as opções de 1 a 7 |

## Requisitos

- Windows com PowerShell 5.1 (já vem instalado no Windows 10 e 11)
- Euro Truck Simulator 2 fechado durante a execução
- Para usar o modelo (veja abaixo): jogo na versão 1.61 ou mais nova

## Instalação

Baixe o projeto com o botão **Code > Download ZIP** do [repositório](https://github.com/DanielTibaes/editor-profile-ets2) e extraia, ou clone com o Git:

```bash
git clone https://github.com/DanielTibaes/editor-profile-ets2.git
```

Mantenha a pasta `templates` junto do arquivo `ets2-profile-editor.ps1`. Sem ela, a opção de criar perfil a partir do modelo não funciona.

## Como usar

Abra o PowerShell na pasta do projeto e rode:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\ets2-profile-editor.ps1
```

O script vai perguntar:

1. **Como criar o perfil:** clonar um perfil existente ou usar o modelo.
2. **Perfil e save de origem** (só ao clonar). O script procura em `Documentos\Euro Truck Simulator 2` e no Steam Cloud.
3. **Nome do novo perfil** e, no modo modelo, o nome da empresa.
4. **O que alterar:** uma ou mais opções separadas por vírgula, como `1,3`, ou `8` para todas.
5. **Confirmação:** o script mostra um resumo com os valores atuais e os novos. Nada é copiado antes de você confirmar.

No final, abra o jogo, escolha o novo perfil e carregue o save.

O perfil é criado em `Documentos\Euro Truck Simulator 2\profiles`, como perfil local. Se quiser usar o perfil no Steam Cloud, ative essa opção dentro do jogo.

### Clonar ou usar o modelo?

- **Clonar:** funciona com qualquer mapa, inclusive mapas mod. A cópia recebe só o save escolhido, para o jogo não abrir um `autosave` sem as alterações.
- **Modelo:** cria um perfil sem precisar de um save seu, mas sempre no mapa Europa do jogo base e sem mods. A sede fica em Liège.

### Como usar um mapa mod (BR Brasil, Rota Factor etc.)

O mapa é definido na criação do perfil e não muda depois. Ativar o mod em um perfil existente não troca o mapa, e isso vale também para perfis criados pelo modelo. Por isso:

1. Ative os mods do mapa no jogo.
2. Crie um perfil novo, escolhendo o mapa na tela de criação.
3. Comece a carreira e salve uma vez.
4. Feche o jogo, rode o script e escolha **Clonar um perfil existente**.

### Saves em formato binário

O script só edita saves em texto (`g_save_format "2"` no `config.cfg`). Na lista, os saves em binário aparecem como `[binario - salve de novo no jogo]` e não podem ser editados.

Se a configuração estiver diferente, o script oferece ajustar o `config.cfg` e cria um backup antes. Depois disso:

1. Abra o jogo.
2. Carregue o perfil e salve.
3. Rode o script de novo e escolha o save novo.

Saves antigos continuam em binário.

## Uso sem perguntas

Passe os parâmetros na linha de comando:

```powershell
# Clonar um save
.\ets2-profile-editor.ps1 -SavePath "C:\caminho\do\perfil\save\1" -NewName "Meu Perfil" -Options 1,2,3 -XpPercent 50 -CashOption 2 -Yes

# Criar a partir do modelo, com todas as opções
.\ets2-profile-editor.ps1 -Template -NewName "Meu Perfil" -CompanyName "Minha Empresa" -Options 8 -XpPercent 50 -CashOption 5 -Yes
```

| Parâmetro | Descrição |
|---|---|
| `-SavePath` | Pasta do save de origem, ou o caminho do `game.sii` |
| `-Template` | Usa o perfil modelo em vez de clonar |
| `-NewName` | Nome do novo perfil |
| `-CompanyName` | Nome da empresa |
| `-Options` | Opções do menu, como `1,2,3` ou `8` |
| `-XpPercent` | Nível de 0 a 100 (para a opção 1) |
| `-CashOption` | `1` = 500 mil, `2` = 1 milhão, `3` = 5 milhões, `4` = 10 milhões, `5` = 30 milhões |
| `-DriverSkills` | Aplica a opção 4 também aos motoristas contratados |
| `-DestRoot` | Pasta onde criar o perfil (padrão: `Documentos\Euro Truck Simulator 2\profiles`) |
| `-Yes` | Pula a confirmação; com ele, o script não altera o `config.cfg`, só avisa |

## Limitações conhecidas

- **XP acima do nível 30 é uma estimativa.** A tabela do script vai até o nível 30; depois disso, usa +6.800 XP por nível. O nível mostrado no jogo pode ser um pouco diferente.
- **Algumas cidades podem não ter concessionária ou agência.** O script libera todas as cidades que têm empresas no save, e o jogo deve ignorar as que não têm esse serviço.
- **O modelo cita caminhões de DLC.** Algumas ofertas de carga rápida usam caminhões de DLC. As dependências foram removidas do `info.sii`, mas o comportamento em uma instalação sem essas DLCs ainda não foi testado.
- **Conquistas, valor pago pelas cargas e preço de peças** não ficam no save, então o script não altera.

Use o script apenas em perfis próprios e no modo single-player. Editar saves não é suportado oficialmente pela SCS Software, e servidores multiplayer têm regras próprias.

## Estrutura do projeto

```
ets2-profile-editor.ps1     script principal
templates/base/             perfil modelo (mapa Europa, jogo base, sem mods)
  profile.sii
  save/1/game.sii
  save/1/info.sii
```

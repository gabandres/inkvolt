# Novidades do Inkvolt Print

Exibido no aplicativo uma vez após uma atualização (ou em Ajuda › Novidades a qualquer momento) e usado na seção «Novidades desta versão» da Microsoft Store.
Cada lançamento recebe um cabeçalho `## x.y.z` antes de ser empacotado (`packaging/pack-msix.ps1` avisa quando a versão não tem nenhum);
`## Next` reúne o que foi concluído desde o último lançamento e nunca é exibido. Linhas curtas, na linguagem do usuário.

## Next

## 1.10.0
- Uma impressora compartilhada aparece na hora em iPhones e iPads, mesmo quando eles já conhecem várias outras impressoras; antes, ela às vezes só aparecia depois de desativar e ativar o compartilhamento novamente.
- Desativar e ativar novamente o compartilhamento de uma impressora a mantém como a mesma impressora, assim os telefones não a listam mais uma vez para cada alteração.
- Ao digitalizar com seu telefone ou uma câmera, o app informa que cada página chegou e que está aguardando a próxima, em vez de mostrar "Digitalizando…".
- Um trabalho enviado direto para uma impressora de rede é acompanhado por no máximo 2 horas; depois disso, o Inkvolt Print informa que o painel de controle da impressora mostra o andamento. Uma impressora cuja contagem de páginas ia e voltava era acompanhada para sempre.
- O nome de arquivo de uma predefinição de digitalização pode preencher {n} com no máximo 32 dígitos (como em {n:D5} ou {n:X8}); um valor maior é recusado no editor da predefinição em vez de travar o salvamento da digitalização.

## 1.9.0
- Registro de impressão: o Registro de impressão na barra lateral lista todos os trabalhos que este PC imprimiu enquanto o Inkvolt Print estava em execução, de qualquer aplicativo, com as páginas de cada mês por impressora e por pessoa. Ele fica salvo neste PC, e você pode desativá-lo ou limpá-lo. Salvá-lo como arquivo CSV faz parte do Inkvolt Pro.
- Compartilhar uma impressora com telefones: uma impressora USB (ou qualquer impressora configurada no Windows) pode receber trabalhos de impressão de telefones Android, Macs e outros computadores na sua rede doméstica. Ative Compartilhar esta impressora na rede na aba Imprimir; o recurso fica desativado até você ativá-lo, funciona apenas em redes que o Windows chama de Privadas e somente enquanto o Inkvolt Print está aberto, e é gratuito.
- Configurar o Wi-Fi de uma impressora nova: Adicionar uma impressora › Configurar uma impressora nova… encontra por perto a rede de configuração de uma impressora nova, conecta-se a ela quando você clica em Conectar, abre a página da própria impressora onde você escolhe seu Wi-Fi e depois traz este PC de volta para a sua rede e encontra a impressora lá. A sua senha do Wi-Fi é digitada apenas na página da impressora ou no Windows, nunca no Inkvolt Print.
- Limpeza pode remover uma cor: as linhas de um formulário vermelho, anotações de caneta azul ou um carimbo ficam brancos, enquanto a impressão em preto permanece. Escolha vermelho, verde ou azul, ou clique na cor da página. Remover furos preenche as marcas redondas dos furos perto das bordas com a cor do papel. Ambos funcionam por digitalização, por predefinição e por página.
- Nomear uma digitalização pelo que está escrito: o nome de arquivo de uma predefinição pode usar {text-date}, {text-title} e {text-number}, uma data, o título e um número de fatura ou pedido lidos na primeira página. Com a etapa de revisão, o nome aparece antes de salvar, para você alterar se quiser.
- Digitalizar direto para Word ou texto: uma predefinição pode salvar o texto lido das páginas como um documento do Word editável ou como um arquivo de texto simples. Títulos e parágrafos são preservados, e as fotos vão para o documento do Word como imagens.
- Unir duas metades: para um original grande demais para o vidro, digitalize uma metade, depois a outra com uma pequena sobreposição, e escolha Unir com a próxima página… na primeira. A sobreposição é encontrada e as metades viram uma única página; se não puder ser encontrada, mova a segunda metade para o lugar com as setas.
- Digitalizar com seu telefone, sem precisar de scanner: Digitalizar com seu telefone na barra lateral (ou na aba Digitalizar de um scanner) mostra um código; aponte a câmera do telefone para ele e tire uma foto de cada página no navegador. Sem aplicativo e sem internet: as fotos vêm direto para este PC pelo seu Wi-Fi, com cada página endireitada e dimensionada como uma digitalização, pronta para revisar e salvar, com suas configurações de digitalização ou uma predefinição.
- Cartões, calendários e colagens em Fotos: faça um cartão dobrado com sua foto na frente e sua mensagem dentro, um calendário com um mês ou um ano inteiro sob cada foto, ou uma colagem de 2 a 9 fotos (arraste uma sobre a outra para trocá-las de lugar). Tudo neste PC, sem conta; imprima como de costume ou salve em PDF.
- Arquivar ou proteger uma digitalização: uma predefinição de PDF pode salvar em PDF/A, o tipo de PDF feito para ser guardado por anos, ou colocar uma senha no PDF (AES-256, como o Inkvolt PDF faz). A senha é solicitada na primeira vez e pode ser guardada no Gerenciador de Credenciais do Windows, nunca na predefinição.
- Imprimir um PDF como livreto, pôster ou várias páginas por folha: escolha Layout. Um livreto imprime em frente e verso na ordem de leitura de uma pilha dobrada (dobre e grampeie), um pôster amplia uma página em várias folhas com marcas de corte, e de 2 a 16 páginas cabem em uma folha.
- Digitalizar com uma câmera: Usar uma câmera, ao lado de Usar seu telefone, mostra sua webcam ou câmera de documentos ao vivo; Capturar página captura cada página, endireitada e dimensionada como uma digitalização, pronta para revisar e salvar.

## 1.8.0
- Frente e verso em um alimentador que digitaliza um lado: marque Frente e verso: virar a pilha (ou a opção da predefinição), digitalize as frentes, vire a pilha quando solicitado e digitalize os versos. As páginas saem na ordem certa; se a bandeja do seu scanner inverte a pilha, Versos na outra ordem corrige isso, e a revisão avisa quando as frentes e os versos não coincidem.
- Páginas alimentadas de lado ou de cabeça para baixo são colocadas na vertical sozinhas quando seu texto mostra qual lado fica para cima (Colocar páginas na vertical, ativado por padrão, também por predefinição). As páginas sobre as quais não há certeza ficam como vieram, e Desfazer as gira de volta.
- PDFs menores: a nova opção Arquivo menor (preto e branco) de uma predefinição salva cada página em preto e branco, muitas vezes com um décimo do tamanho ou menos. Digitalizações em preto e branco também são salvas assim.
- Compartilhar um scanner na rede agora é gratuito para sempre, não faz mais parte do Inkvolt Pro.
- Pronto para o novo driver de impressora do Windows: Sobre esta impressora informa qual driver o Windows usa para ela, se a impressora funciona com o driver próprio do Windows e seu modo de impressão protegida, e Configurar com o driver do Windows a adiciona novamente desse jeito ao lado da antiga. Um scanner que só funciona pelo driver do Windows é sinalizado, pois não digitalizará no modo de impressão protegida.
- Frente e verso em uma impressora que imprime de um lado só: Imprimir um PDF, Em lote e Copiar oferecem Imprimir em frente e verso manualmente. As frentes são impressas, depois o aplicativo mostra como recolocar a pilha na sua impressora (ele pergunta de que lado saíram as folhas impressas) e imprime os versos.
- Imprimir a área de transferência: na aba Imprimir, Imprimir a área de transferência imprime o texto que você copiou (diagramado em páginas, com as opções de sempre), uma imagem copiada através de Fotos ou arquivos que você copiou no Explorador de Arquivos.
- Digitalizações recentes: Digitalizações recentes… na aba Digitalizar lista suas últimas digitalizações salvas de todos os scanners, para abrir, mostrar na pasta, enviar novamente por e-mail ou imprimir. A lista fica neste PC.

## 1.7.0
- Imprimir em uma impressora de rede que não está configurada no Windows: Imprimir um PDF, Copiar e Imprimir fotos agora enviam as páginas direto para a impressora pela rede, no formato próprio dela, sem driver e sem administrador. Onde o Windows tem uma fila para ela, a fila continua sendo o padrão e Imprimir também oferece "Imprimir direto na impressora". Você vê cada página sendo impressa, e o cartão da fila de impressão lista os trabalhos da própria impressora.
- A impressão em lote, o "imprimir uma cópia" de uma predefinição de digitalização e os avisos de trabalho também funcionam com essas impressoras: cada arquivo de um lote vai direto para a impressora, um após o outro, e um trabalho interrompido pela impressora encerra o lote ali para que nada seja impresso duas vezes; os avisos de trabalho informam quando a impressora desiste do seu trabalho ou ele para de avançar. A linha de comando também imprime nelas: informe o nome da impressora ou seu endereço como ipp://….
- Copiar com a própria impressora: uma impressora HP que aceita solicitações de cópia pode copiar por conta própria quando você clica em Copiar, com as configurações do painel de controle dela, sem precisar de fila do Windows. Por este PC continua sendo a opção para escolher número de cópias, agrupamento, frente e verso e visualização.
- As cópias pelo PC podem colocar 2 ou 4 páginas em cada folha, sair sem agrupar (todas as cópias da página 1, depois as da página 2) e aguardar em uma visualização até você clicar em Imprimir.
- Digitalizar pelo botão da impressora: em uma impressora HP que oferece Digitalizar para computador, ative-o na aba Digitalizar e este PC aparecerá no painel da impressora; escolha-o lá e pressione Digitalizar, e a predefinição de digitalização escolhida será executada aqui enquanto o Inkvolt Print ou seu ícone na área de notificação estiver em execução. Um scanner cujo driver do Windows informa o botão faz o mesmo; uma impressora sem nenhum dos dois avisa isso.
- Inkvolt Pro (gratuito por enquanto): compartilhe um scanner na rede. Um scanner USB, ou uma multifuncional que não consegue digitalizar pela rede, pode ser usado em um aplicativo de digitalização no iPhone ou Android, na Captura de Imagem de um Mac ou em outro PC: ative Compartilhar este scanner na rede na aba Digitalizar, ou pelo ícone na área de notificação. Fica desativado até você ativar, funciona apenas em redes que o Windows chama de Privadas e somente enquanto o Inkvolt Print está em execução, e o cartão mostra a impressão digital do certificado para comparar.
- Scanners cujo driver do Windows envia apenas PDF agora digitalizam como qualquer outro: suas páginas chegam à aba Digitalizar para revisão, reconhecimento de texto e predefinições.
- Scanners com um driver do Windows mais recente (WIA 2.0): a aba Digitalizar mostra o andamento de cada página, Parar interrompe a página que está sendo digitalizada, e o vidro e o alimentador oferecem suas próprias resoluções.
- Um scanner cujo único driver é um antigo driver TWAIN de 32 bits agora aparece pelo nome e informa por que não pode ser usado aqui e qual driver instalar, em vez de nem sequer aparecer.
- O recurso Clarear da limpeza não deixa mais as páginas desbotadas difíceis de ler depois que suas cores são restauradas.
- Os suprimentos mostram as páginas restantes e o rendimento nominal de um cartucho cheio em mais impressoras: impressoras HP mais novas e impressoras de outras marcas que contam o toner em páginas. As páginas impressas e as páginas desde a instalação de cada cartucho também são exibidas.
- Acesso SNMP… com um usuário SNMPv3 (Inkvolt Pro) funciona com mais impressoras: escolha o protocolo que a impressora usa ao lado de cada frase secreta, SHA-256, SHA-1 ou MD5 para autenticação e AES-128, AES-192, AES-256 ou DES para privacidade.
- Uma impressora cuja página web fica em uma porta própria pode ser adicionada por esse endereço (por exemplo http://192.168.1.20:8080), e uma que anuncia sua página na rede é lida lá automaticamente.
- O status da impressora mostra o que o painel de controle dela diz, quando isso informa mais do que o status.
- Impressoras que o Windows configurou via WSD agora mostram o próprio status e os níveis de toner ou tinta quando a impressora responde a SNMP, como fazem as impressoras em porta TCP/IP.
- Uma impressora adicionada, removida ou renomeada no Windows aparece na lista de impressoras, sai ou assume o novo nome em cerca de um segundo, em vez de esperar a próxima verificação.
- A digitalização em lote também divide em códigos QR: uma folha com código QR ou código de barras escrito PATCHT (como o Paperless-ngx imprime) inicia um novo arquivo, como uma folha de código patch. A folha separadora que o Inkvolt Print salva para você agora traz um ao lado das barras.
- Obter o driver agora também encontra drivers da Canon, HP e Brother e da PFU (scanners Fujitsu e Ricoh fi e SP), cada um no site do próprio fabricante e assinado por ele, como já faz para a Epson.
- Novidades aparece em espanhol quando o Inkvolt Print está em espanhol.
- Ajuda › Abrir pasta de registro na versão da Microsoft Store abre a pasta onde o registro realmente fica guardado, que o Windows mantém na pasta do pacote do aplicativo. Obter o driver mostra a licença da Brother, Canon e PFU antes de baixar o driver, que você aceita com Aceitar e baixar.

## 1.6.0
- Acesso SNMP… agora consulta a impressora antes de salvar: informa qual parte a impressora recusou, ou que outro dispositivo respondeu, e não salva nada; quando a impressora não responde, ou a recusa pode não vir da sua impressora, Salvar mesmo assim mantém como está.
- Uma impressora que recusa o login SNMP agora informa isso, indicando qual parte e exibindo um botão Acesso SNMP…, em vez de aparecer como offline, e sua notificação também avisa.

## 1.5.0
- Um scanner USB conectado sem driver agora aparece na lista de impressoras e na aba Digitalizar como "Conectado, precisa do driver", no instante em que é conectado.
- Obter o driver: para scanners e impressoras Epson, o Inkvolt Print encontra o driver próprio da Epson para o seu modelo e seu PC no site da Epson e mostra o nome, a versão e o tamanho. Baixar da Epson abre esse download no navegador; execute o instalador da Epson e o Inkvolt Print vê o scanner chegar e abre a aba Digitalizar. (Instalado pelo instalador próprio do Inkvolt em vez da Store, ele baixa o driver, verifica se a Epson o assinou e o instala quando você autoriza.)

## 1.4.0
- Scanners que têm apenas um driver TWAIN (scanners de filme, scanners de mesa antigos e scanners de documentos) agora aparecem na lista de impressoras, com sua impressora ou sozinhos, e digitalizam na aba Digitalizar como qualquer outro: vidro ou alimentador, frente e verso, colorido, tons de cinza ou preto e branco, com a mesma revisão, limpeza e predefinições. A janela própria do driver não se abre. Um scanner que também possui driver do Windows é listado apenas uma vez.
- Digitalizar em preto e branco: a opção Cor na aba Digitalizar agora oferece essa opção quando o scanner suporta.
- Scanners TWAIN continuam aparecendo quando o serviço de scanners do Windows não está respondendo, e os scanners listados anteriormente permanecem na lista.
- Avisos de trabalho: um trabalho ausente em uma verificação da fila não reinicia mais a contagem de trabalho parado, um trabalho com falha é avisado a tempo mesmo com a janela fechada, e um trabalho recém-avisado não é avisado novamente após reiniciar.
- A observação da limpeza sobre a borda do papel conta apenas as páginas em que a borda foi procurada e não encontrada, não uma página recortada por você ou ainda não verificada.

## 1.3.0
- Uma impressora USB para a qual o Windows não tem driver agora aparece na lista de impressoras como *Conectada, precisa do driver*, com o passo a passo do que fazer: a página de drivers do fabricante (da HP para uma HP), as atualizações opcionais do Windows Update ou adicioná-la no Windows. Ele avisa quando o modo de impressão protegida do Windows impede drivers dos fabricantes. Quando o driver já está instalado mas o Windows não criou uma fila, *Configurar* cria uma. Algumas impressoras antigas (lasers USB baseadas no host) funcionam apenas com o driver do fabricante.
- Impressoras USB (e outras configuradas no Windows) podem mostrar seus níveis de tinta ou toner: uma impressora que o Windows configurou com seu próprio driver IPP, por USB ou pela rede, é consultada sobre níveis e problemas do mesmo modo que uma impressora Wi-Fi, e a página informa de onde eles vieram. Com o driver do fabricante, o driver é consultado em seguida ("Do driver dela"), quando ele sabe informar. Uma que não informa nenhum diz "Não informado por esta impressora".
- O Inkvolt Print fala espanhol: ele segue o idioma do Windows, ou você pode escolher em Configurações › Idioma (Igual ao Windows, English ou Español). Entra em vigor na próxima vez que o aplicativo iniciar.
- Imprimir um PDF funciona em qualquer tela: o botão Imprimir permanece visível abaixo das opções, que rolam quando a janela é baixa. Em telas menores, ele podia ficar cortado sem como alcançá-lo.
- Em uma tela de notebook pequena ou com escala, a janela cabe: a barra de título com Minimizar e Fechar ficava acima da borda superior da tela.
- Windows 10: a janela tem fundo sólido e todos os ícones aparecem.
- Revisão da digitalização: uma página restaurada com Desfazer, a página que ocupa o lugar de uma excluída e uma página que você move agora deslizam suavemente para o lugar. Nada se move enquanto uma digitalização ou salvamento está em andamento, ou quando os efeitos de animação do Windows estão desativados.
- Ctrl+K alcança o menu de cada impressora: digite o nome de uma impressora e um comando ("recepção corrigir") para executá-lo nessa impressora imediatamente, sem mostrá-la antes.
- Impressoras que respondem apenas a SNMP podem ter sua própria comunidade: informe-a em Acesso SNMP ao adicionar a impressora pelo endereço, ou altere-a depois pelo menu da impressora (Acesso SNMP…). Ela é guardada no Gerenciador de Credenciais do Windows e usada apenas para ler a impressora.
- Inkvolt Pro (gratuito por enquanto): SNMPv3. Para uma impressora que responde apenas a SNMPv3, informe o nome de usuário e as duas frases secretas em vez de uma comunidade. Cada solicitação é assinada e criptografada (SHA-256, AES-128), e o Inkvolt Print informa se a impressora recusou o nome de usuário ou uma frase secreta.
- A mensagem longa de um problema da impressora quebra de linha no cartão de status; antes ela era cortada na borda do cartão.

## 1.2.0
- Impressão em lote: Imprimir › Em lote aceita vários PDFs e imagens, ou uma pasta. Cada arquivo tem suas próprias cópias, páginas, lados e papel, e você vê quantas folhas cada um usa e o total antes que qualquer coisa seja impressa. Eles vão na ordem, cada resultado é listado, e um lote que para informa onde parou e continua dali sem imprimir nada duas vezes.
- Um arquivo que mudou ou desapareceu depois da estimativa não é impresso, e um intervalo de páginas ou papel que um arquivo ou impressora não possui é informado na própria linha, nunca alterado silenciosamente.
- Inkvolt Pro (gratuito por enquanto): salve um lote como lista, guarde os resultados como arquivo de planilha, imprima uma pasta conforme os arquivos chegam nela e imprima a partir de um script ou tarefa agendada com inkvoltprint print --list arquivo --printer nome.
- Limpar digitalizações: recorte no tamanho do papel, clareie o fundo e remova manchas, tire os pontos de imagens impressas e restaure cores desbotadas. Ative cada opção para uma digitalização ou predefinição, ou por página na revisão, e Desfazer desfaz a alteração.
- PDFs pesquisáveis agora funcionam em qualquer idioma: grego, cirílico, árabe, hebraico, chinês, japonês, coreano e outros podem ser encontrados no texto oculto. Se você tiver vários idiomas de OCR instalados, escolha um em Idioma do texto.
- Frota: uma nova página, acessível pelo botão no topo da lista de impressoras, mostra todas as impressoras de uma só vez com seu estado, níveis de tinta ou toner, contagem de páginas, firmware e data da última leitura, com as que têm problemas primeiro.
- Corrigir… agora também funciona em impressoras conhecidas apenas pelo Windows (USB, compartilhadas de outro PC): ele encontra uma fila pausada, Usar impressora offline e trabalhos parados, e corrige depois de perguntar. Retomar uma fila e desativar Usar impressora offline agora perguntam antes em todas as impressoras, já que os trabalhos em espera começam a imprimir.
- Inkvolt Pro (gratuito por enquanto): Exportar… na página Frota salva a lista como arquivo de planilha ou JSON, inkvoltprint status --all --json fornece a mesma lista para um script ou tarefa agendada, e Corrigir tudo retoma filas pausadas e desativa Usar impressora offline em todo lugar, perguntando sobre cada uma.
- Avisos de trabalho: ative "Avise-me quando um trabalho de impressão meu falhar ou ficar parado" nas Configurações, e a falha do seu trabalho, ou nenhum avanço por 5 minutos em uma impressora pronta (15 se a impressora disser que está imprimindo), avisa você, com o nome do documento e Abrir a fila. Um trabalho parado avisa novamente apenas se avançou nesse meio tempo, no máximo três vezes. Desativado a menos que você ative. Trabalhos de outras pessoas nunca geram aviso.
- Relatar um problema pode gravar a impressora exibida: cada resposta que o Inkvolt Print lê dela, somente leitura, com números de série, endereços e nomes removidos, salva como um arquivo .zip para você ler e anexar. Nada é enviado.

## 1.1.0
- Histórico de tinta e toner: o Inkvolt Print guarda uma leitura por dia no seu PC e mostra um gráfico dos níveis no último ano, aproximadamente quantos dias restam em cada cartucho e quantas páginas você imprimiu desde que ele foi instalado. Alertas de pouca tinta também informam quantos dias restam. Exportar histórico… salva tudo em um arquivo de planilha (um recurso do Inkvolt Pro, gratuito por enquanto).
- Monitoramento de firmware: quando o firmware de uma impressora muda, o Inkvolt Print informa no cartão de status ("Firmware alterado de … para … em …") e, com os alertas ativados, uma vez em uma notificação.
- Impressoras HP: Manter meus cartuchos funcionando, em Configurações da impressora › Firmware, desativa as atualizações automáticas de firmware com um clique, para que uma atualização que bloqueie cartuchos não HP não se instale sozinha, e verifica se a impressora manteve a configuração.
- Pressione Ctrl+K para encontrar qualquer comando digitando: mostrar outra impressora, ir para Digitalizar, executar uma predefinição de digitalização, corrigir problemas de impressão, abrir Configurações… Seta para cima e para baixo escolhem, Enter executa.
- Com um Tamanho de texto grande ou uma janela pequena, a lista de impressoras se recolhe em um botão Impressoras no topo, como fazem as Configurações do Windows, para que a página da impressora mantenha seu espaço. Clique nele para abrir a lista sobre a página.
- A troca de abas ou impressoras, e uma nova linha de status, agora aparecem com uma breve transição suave em vez de mudar de repente. Nada se move quando os efeitos de animação do Windows estão desativados.
- Os alertas agora são notificações nativas do Windows: uma por impressora, com os botões Abrir impressora e Pausar alertas, mantidas na Central de Notificações. Um alerta mais recente da mesma impressora substitui o que ainda está sendo exibido.
- Versão da Microsoft Store: Iniciar com o Windows é oferecido em Configurações › Área de notificação e alertas, abrindo direto na área de notificação; Aplicativos de inicialização do Gerenciador de Tarefas o lista e pode desativá-lo.
- Ajuda › Inkvolt Pro…: insira uma chave de licença do Inkvolt Pro, veja para quem ela está licenciada ou remova-a. Uma chave cobre o Inkvolt Print e o Inkvolt PDF neste PC: insira em qualquer um dos dois aplicativos e o outro a encontra. Tudo continua gratuito durante o lançamento dos aplicativos; uma licença (US$ 19, pagamento único, sem conta, verificada no seu PC e nunca enviada a lugar nenhum) apoia o projeto e mantém os recursos Pro para você quando eles passarem a pedir uma chave.
- Desfazer na revisão da digitalização: uma página excluída volta, assim como um giro, um recorte ou uma movimentação (botão Desfazer, ou Ctrl+Z). A linha de status mostra como fazer isso depois que você exclui uma página.
- Na revisão da digitalização, Ctrl+R e Ctrl+L giram a página selecionada e Ctrl+S a salva como PDF. A Ajuda lista todos eles.
- Scanners que só enviam PDF pelo alimentador agora digitalizam como os outros: as páginas aparecem para revisão, e girar, recortar, endireitar, pular páginas em branco, dividir em arquivos, reconhecimento de texto e predefinições funcionam normalmente. Salvo como PDF sem alterações, o arquivo é exatamente o PDF que o scanner enviou.
- O Inkvolt Print segue o Tamanho do texto do Windows (Configurações › Acessibilidade): tudo aumenta junto com ele. Em tamanhos grandes, as abas quebram de linha em ordem e os botões Imprimir um PDF e Digitalizar passam para baixo do nome da impressora.
- Perguntas ("Remover esta impressora?", "Descartar as páginas?") exibem a pergunta como título e na barra de título, com a explicação abaixo; uma mensagem apenas informativa fecha com Fechar.
- As legendas das Configurações de digitalização não ficam mais cobertas pela barra de rolagem, assim como o texto de Novidades.
- Links e os botões de página da revisão da digitalização (girar, recortar, excluir) estão mais fáceis de clicar (pelo menos 24 px) e mostram um contorno de foco quando alcançados com Tab.
- O campo de endereço de Adicionar uma impressora mostra um exemplo até você digitar.
- Para quem está ajudando a testar impressoras: inkvoltprint record <endereço> <pasta> salva tudo o que o Inkvolt Print lê de uma impressora, com números de série, endereços e nomes removidos, para que as peculiaridades da sua impressora possam fazer parte dos testes do Inkvolt Print. Ele apenas lê; nada na impressora é alterado.

## 1.0.8
- Depois que o Inkvolt Print salvar algumas digitalizações ou enviar algumas impressões ao longo de pelo menos dois dias, ele pergunta uma única vez se você gostaria de avaliá-lo na Microsoft Store, na própria janela da Store. Ele nunca pergunta de novo, seja qual for a sua escolha.

## 1.0.7
- Adicionar uma impressora: busca na sua rede impressoras que não aparecem sozinhas, restaura impressoras que você removeu, ajuda com impressoras USB e aceita um endereço ou URL da impressora.
- Digitalizações não salvas voltam após uma falha em mais casos (depois de salvar, enquanto uma caixa de diálogo estava aberta), e uma impressora com digitalizações não salvas continua na lista.
- A revisão da digitalização cabe em janelas pequenas.
- Abrir vários arquivos de uma vez com o Inkvolt Print abre todos eles.
- Relatar um problema oculta mais dados pessoais e mantém legíveis os números de modelo e as versões.

## 1.0.6
- A Visão geral usa a janela inteira: seus cartões se alargam para preenchê-la.
- Adicionar uma impressora pelo endereço: digite o endereço imediatamente.

## 1.0.5
- Digitalizações não salvas são mantidas em disco: após uma falha, o fechamento forçado do aplicativo ou uma queda de energia, elas voltam na aba Digitalizar.
- Configurações em um só lugar: tema, onde as digitalizações são salvas, abrir digitalizações no Inkvolt PDF, predefinições, área de notificação e alertas e Restaurar padrões.
- Ajuda (F1): atalhos de teclado, dicas para encontrar uma impressora, Relatar um problema (copia os detalhes que um relato precisa, com endereços e números de série mascarados; nada é enviado pelo aplicativo) e a pasta de registro.
- A lista de impressoras informa por que uma impressora precisa de atenção ("Pronta · Yellow ink is low").
- Copiar: tamanho real ou ajustar ao papel.
- Tema claro ou escuro, e a janela abre onde você a deixou.
- Sem nenhuma impressora encontrada ainda, a janela não mostra mais botões e abas de impressora que não têm sobre o que agir.

## 1.0.4
- Os níveis de tinta e toner continuam aparecendo quando o relatório de suprimentos próprio de uma impressora falha: o Inkvolt Print recorre ao protocolo padrão de impressão.
- Cada atualização de status consulta a impressora uma vez em vez de duas.
- Uma impressora mais antiga conhecida apenas por SNMP que muda para um novo endereço de rede é verificada pelo número de série antes de ser exibida lá.

## 1.0.3
- Impressoras já configuradas no Windows também aparecem, incluindo impressoras USB, com o status informado pelo Windows e pelo driver da impressora, a fila de impressão e impressão de PDFs e fotos.
- Impressoras de rede mais antigas que não falam IPP mostram seu status, alertas e níveis de toner ou tinta por SNMP.
- Scanners sem AirScan (USB ou com apenas um driver do Windows) digitalizam pelo Windows, com os mesmos recursos de revisão, PDF pesquisável, predefinições e cópia.
- Uma fila que o Windows não consegue alcançar (o PC de uma impressora compartilhada desligado, um serviço de impressão parado) informa isso em vez de parecer removida.

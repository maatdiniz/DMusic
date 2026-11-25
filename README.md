# DMusic

Cliente iOS nativo de streaming de música Hi-Res construído em **Swift / SwiftUI** (zero dependências externas) para servidores **Navidrome / OpenSubsonic v1.16.1**, com motor de mixagem **DJ Automix Dual-Deck** em `AVAudioEngine`, **Smart Shuffle consciente de BPM, Roda de Camelot e Vibe/Timbre**, **Compensação de Volume** e integração nativa com **Last.fm**.

---

## Principais Recursos

- **Streaming Bit-Perfect & Hi-Res:** Reprodução nativa de FLAC, ALAC, AIFF, WAV, M4A e MP3 em qualidade original (`format=raw`) ou transcodificação configurável separadamente para Wi-Fi e Dados Móveis.
- **Reprodução Gapless & Dual-Deck Automix:**
  - `AVQueuePlayer` *gapless* puro quando o Automix está desligado ou em álbuns na ordem original.
  - Motor `AVAudioEngine` **Dual-Deck 48 kHz Stereo** com `AVAudioUnitTimePitch` (rampa de BPM sem alterar tom), EQ de 5 bandas (Troca de Graves / 3 Bandas / Filtros Passa-Alta e Passa-Baixa) e cauda de reverb opcional.
- **Ordenação Inteligente (`SmartShuffler`) com Vibe 24D:**
  - Pontuação de compatibilidade `0–100` combinando **BPM (40 pts)**, **Vibe/Timbre acústico 24D (30 pts)**, **Roda de Camelot 1A–12B (22 pts)** e **Energia (8 pts)**, evitando quebras bruscas de estilo/emoção mesmo quando BPM e tom coincidem.
- **Compensação de Volume (Loudness Normalization):**
  - Medição de Loudness Integrada em **LUFS segundo norma ITU-R BS.1770-4** com filtro K (shelf de agudos + passa-alta de 38 Hz), medição de True Peak e cache persistente em disco (`Caches/loudness.json`). 4 níveis nos Ajustes (*Desligada*, *Baixo `-16 LUFS`*, *Médio `-14 LUFS`*, *Alto `-11 LUFS`*) e proteção anti-clipping em `-0.5 dBFS`.
- **Espectrograma Rolante & Alinhamento de Batidas (Estilo Rekordbox):**
  - Visualização opcional na tela de reprodução com espectrograma em tempo real de Deck A e Deck B de borda a borda, zoom dinâmico em compassos (`4 / 6 / 10 BARS`), alinhamento de fase periódico em grade de 4 compassos (16 batidas), servo PLL de microajuste de fase de bumbos e contagem regressiva de compassos para o mix.
- **Offline Primeiro:** Downloads permanentes sem transcodificação, cache LRU configurável de faixas recentes e cache persistente de capas.
- **AirPlay Áudio, Bluetooth & Now Playing:** Integração completa com `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter` (Tela Bloqueada, AirPlay Áudio e Now Playing do CarPlay) e recuperação transparente em trocas de rota Bluetooth sem reiniciar a faixa.
- **Last.fm + Sanitização de Tags:** Autenticação nativa `auth.getMobileSession`, fila offline persistente, regra oficial de 50%/4 min e normalização avançada de tags (Unicode NFC, artista principal, remoção de sufixos de remaster/deluxe).

---

## Histórico de Versões

> **Nota sobre o versionamento:** O histórico abaixo organiza a evolução real do projeto em duas grandes eras contínuas, sem saltos de numeração:
> - **Era v1.x (v1.0 a v1.8):** A fundação do streaming Hi-Res, recursos offline, Last.fm, rebrand para DMusic e os primeiros experimentos e tentativas de mixagem DJ. Itens experimentais que foram posteriormente descontinuados ou reformulados estão devidamente tachados com suas explicações.
> - **Era v2.x (a partir da v2.0):** A grande virada arquitetural do **Automix v2** (onde a análise passou a ser pré-computada em grade constante pelo servidor, a CPU despencou de 41% para 11%, os pratos de vinil deram lugar ao novo palco de meias capas retas e o espectrograma estilo Rekordbox entrou em ação).

### v2.2 (Atual) — Limpeza Estrutural, `CoverStageView` e Otimização de Estado `@Observable`
- **Consolidação do Palco de Capas (`CoverStageView`):** Remoção definitiva de todo o código legado da era dos pratos giratórios (`DJDeckStageView` / `DJDualJogStageView`, interpolação circular de vinil e constantes de morph), renomeando o módulo e seus estados para `CoverStageView`, `CoverStageMode`, `CoverStageMetrics` e `CoverBPMChip`.
- **Fim de Invalidações `@Observable` a 60 Hz:** Eliminação de `transitionMixProgress` / `onMixProgress` (que mutavam o `AudioPlayerManager` 60 vezes por segundo durante toda a mixagem sem nenhuma View consumidora) e remoção do array observável `eventLogs` (`AutomixEventLog`), direcionando os logs diretamente ao `AppLogger` sem re-renderizar a árvore SwiftUI.
- **Remoção de Código Legado v1.x (-310 linhas líquidas):** Exclusão de 10 métodos órfãos de ordenação harmônica e cálculo de fase da antiga v1.2 em `TrackAnalysisStore`, limpeza de `TrackMixBadgeView` no `NowPlayingView` e simplificação de `CoverArtView` e `SmartShuffler`.
- **Guia e Ajustes Atualizados:** `AutomixGuideView` e `SettingsView` revisados para documentar o Palco de Meias Capas com Halo LED, o Espectrograma RGB estilo Rekordbox e a pontuação real de 0–100 pts do `SmartShuffler` com Vibe 24D.

### v2.1 — Espectrograma Rekordbox, Alinhamento 4-Bar e Transição Suave
- **Espectrograma Rolante em Tempo Real:** Visualização opcional estilo Rekordbox/djay Pro com formas de onda dinâmicas dos Decks A e B de borda a borda, zoom em compassos (`4 / 6 / 10 BARS`) e contagem regressiva de compassos para o início e término da mixagem.
- **Phase Lock de 4 Compassos (16 Batidas):** Trava periódica que impede entradas desalinhadas no meio de uma frase musical, garantindo sincronia perfeita no tempo 1 do compasso.
- **Servo PLL de Fase & BPM Local:** Microajuste em tempo real de fase de bumbos e interpolação de BPM local na janela de transição para compensar faixas de andamento variável.
- **Saída Musical Gradual:** Decaimento em curva cosseno suave no terço final da transição (mantendo presença e energia até 70% da mistura), eliminando saídas secas ou cortes bruscos.

### v2.0 — A Grande Virada: Automix v2 (Servidor Decide, App Executa)
- **Ruptura Arquitetural de Mixagem:** Fim da dependência de análise pesada em tempo real no iPhone; o servidor passou a ser a fonte de verdade absoluta com grade de tempo constante por regressão (`postprocess.py`), detecção de tempo 1 por múltiplos critérios, seções no downbeat e separação `demucs` para detecção de vocais.
- **Redução Drástica de Energia:** Consumo de CPU medido em Release no iPhone caiu de **41% para 11%** (monitor adaptativo em 60 Hz só nas janelas críticas, sem IPC por tick, reverb e TimePitch ociosos em bypass, e análise local parada no Modo Pouca Energia).
- **Novo Palco Visual de Capas:** Fim definitivo dos pratos de vinil girando; estreia do palco de meias capas retas de borda a borda com vão central e halo luminoso responsivo no ajuste de BPM e na troca de faixa.
- **Áudio Profissional & Loudness Integrado:** Limiter master no grafo de áudio, curvas de equalização inspiradas no mixer Pioneer DJM-900NXS2 e compensação de volume migrada para norma **ITU-R BS.1770-4 (LUFS)** com cache persistente em disco.
- **Interface Unificada:** Novo painel único de ações (`ActionMenu`), indicador global de carregamento, dock inferior indicando tipo/qualidade do arquivo e sincronização de grade do servidor.

---

### v1.8 — Refinamento de Precisão & Sincronia de Áudio
- **Compensação de Preroll & Alinhamento Sample-Accurate:** Correção da defasagem de 40 ms no disparo do Deck B para eliminação de flamming nas batidas.
- **Verificador de BPM Real no PCM:** Inspeção de áudio decodificado a 0.1 BPM para contornar pequenos arredondamentos de andamento.
- **Smart Shuffler Aprimorado:** Deduplicação inteligente de títulos repetidos na fila e isolamento de pool IA com similaridade acústica.
- **Estabilidade do Sistema de Áudio:** Migração do ciclo de vida de `AVAudioSession` para despacho assíncrono em segundo plano (eliminando avisos `SessionCore`/`AVAudioSession_iOS`) e integração de `AppLogger` contínuo no console.

### v1.7 — Rebrand DMusic, Compensação de Volume & Refinos de Áudio
- **Identidade DMusic:** Renomeação oficial do aplicativo e refatoração de referências internas para **DMusic**.
- **Compensação de Volume nos Ajustes:** Primeira versão do nivelamento automático de ganho com proteção contra clipping.
- ~~**Saída em Passa-Alta com Volume Cheio:** Na curva *Sobrepor* com filtro Passa-Alta na saída, a faixa anterior mantém 100% de volume enquanto o filtro limpa a saída.~~ *(Substituído na v2.1 por decaimento suave em cosseno no terço final para eliminar saídas secas e abruptas).*
- **Resiliência Bluetooth:** `AutomixAudioEngine` preserva o timestamp exato em trocas de rota de áudio (`AVAudioEngineConfigurationChange`), impedindo a faixa de reiniciar do zero.

### v1.6 — Smart Shuffle Acústico (Vetor de Vibe 24D)
- **Extrator Acústico 24D:** Módulo no `mix-analyzer` extraindo 12 coeficientes MFCC, 4 bandas de energia espectral, decomposição harmônica/percussiva (HPSS), brilho, aspereza, contraste espectral e regularidade rítmica com padronização Z-score + normalização L2.
- **Pontuação Multicritério:** Integração de similaridade de Vibe no `SmartShuffler` ponderando BPM (40%), Vibe acústico (30%), Roda de Camelot (22%) e Energia (8%), com exibição da nota nos logs de diagnóstico.

### v1.5 — Design Unificado & Mix DJ Contextual
- **Ajustes Redesenhados:** Interface de configurações padronizada no visual escuro em cards minimalistas alinhados à Fila de Reprodução.
- **Mix DJ Contextual:** Opção de disparar o DJ Mix diretamente no menu de toque longo de qualquer faixa (com opção para mixar o álbum/playlist atual ou toda a biblioteca).
- **MiniPlayer & Camelot:** MiniPlayer refinado e tags da Roda de Camelot padronizadas ao lado da duração em paleta suave sem bordas.
- **CarPlay Universal:** Limpeza de templates legados dedicados, garantindo compatibilidade universal via Now Playing nativo do iOS.

### v1.4 — Mesa DJ Visual & Entradas Beat-on-Beat
- ~~**Palco visual `DJDualJogStageView` com animação de decks girando durante a transição, slider DJ com zona de BPM destacada e exibição de BPM ao vivo.**~~ *(Abolida a animação de pratos de vinil girando e o controle manual deslizante; substituídos na v2.0 pelo palco de meias capas retas e na v2.1 pelo espectrograma Rekordbox).*
- **Detecção `bar_beat`:** Identificação de presença de batida por compasso (35–175 Hz) para transições *beat-on-beat* ou entradas no drop após silêncio vocal.
- **Diagnóstico & Estúdio:** Suporte a bibliotecas longas (1.000+ faixas), correção de saltos de oitava/half-time e painel de diagnóstico (`AutomixLogsView`) com Estúdio Automix.

### v1.3 — Arquitetura Sidecar (`allin1` + `librosa`) & Motor Dual-Deck
- **Pipeline de Análise Estrutural:** Separação instrumental `demucs` (GPU MPS) + segmentação musical `allin1` (`intro`/`verse`/`chorus`/`outro`, beats e downbeats) + Camelot e energia via `librosa`.
- **Servidor Mix Inicial:** Primeiro servidor leve em FastAPI (`:4534`) para ingestão e cálculo de planos de transição por fraseado (*Pair-Wise Phrase Matching*).
- **Motor Dual-Deck 48 kHz:** Motor `AVAudioEngine` estéreo a 48 kHz (`DeckPCMStreamer`), rampa de BPM com `AVAudioUnitTimePitch`, disparo ancorado em `AVAudioTime` e equalizador com Troca de Graves (Bass Swap de `-24 dB`).

### v1.2 — Primeiro Automix Local & Metadados Avançados
- ~~**Análise local via `Accelerate/vDSP` (`TrackAnalysisStore`) para BPM decimal, fase de batida e tonalidade Camelot no próprio aparelho.**~~ *(Abolida na v2.0: a análise no celular causava alto consumo de bateria e aquecimento, sendo substituída pela análise prévia no servidor).*
- **`ArtistParser`:** Separação inteligente de múltiplos artistas por vírgula, permitindo navegação individual por artista e discografia de participações.
- **Novo Visual do Now Playing:** Fundo dinâmico com *ambient blur*, título com *marquee* vai-e-volta estilo Spotify e cabeçalho contextual de navegação.

### v1.1 — Ecossistema Offline & Social
- **Last.fm Nativo:** Autenticação `auth.getMobileSession`, fila offline persistente (`LastFMClient`, `ScrobbleManager`), sanitização rigorosa de tags e regra de 50%/4 minutos.
- **Downloads Offline & Cache:** Downloads locais permanentes sem transcodificação (`DownloadManager`), cache LRU de faixas recentes (`RecentSongsCache`) e cache persistente de capas.
- **Fila Interativa:** `QueueView` com suporte a reorganização manual de músicas por drag-and-drop.
- **Áudio & Conectividade:** Reprodução *gapless* nativa (`AVQueuePlayer`), Sleep Timer configurável e suporte a AirPlay exclusivamente como áudio.

### v1.0 — Base Hi-Res OpenSubsonic
- **Cliente Nativo Hi-Res:** Construído em Swift e SwiftUI puro com Dark Mode nativo conectado ao protocolo OpenSubsonic v1.16.1.
- **Streaming Bit-Perfect:** Reprodução de formatos sem perdas (FLAC, ALAC, AIFF, WAV, M4A, MP3 em `format=raw`).
- **Segurança & Navegação:** Autenticação MD5 + Salt com credenciais salvas no Keychain do iOS; abas *Início*, *Biblioteca* e *Buscar*; MiniPlayer persistente, suporte a áudio em segundo plano e controles na Tela Bloqueada via `MPRemoteCommandCenter`.

---

## Estrutura do Projeto

- `DMusic/Models/` — Modelos OpenSubsonic (`Song`, `Album`, `Artist`, `Playlist`, `PlaybackSource`) e modelos de mixagem (`TransitionPlan`, `CamelotKey`, `ServerTrackMixInfo`).
- `DMusic/Services/` — `SubsonicClient`, `AudioPlayerManager`, `AutomixAudioEngine`, `SmartShuffler`, `TrackAnalysisStore`, `MixServerClient`, `DownloadManager`, `RecentSongsCache`, `ImageCache`, `LastFMClient`, `ScrobbleManager`, `ArtistParser`, `CacheSettings`.
- `DMusic/ViewModels/` — `AuthViewModel`, `HomeViewModel`, `LibraryViewModel`, `SearchViewModel`.
- `DMusic/Views/` & `Components/` — Telas e componentes SwiftUI (`NowPlayingView`, `CoverStageView`, `ScrollingSpectrogramView`, `ActionMenu`, `QueueView`, `SettingsView`, `AutomixGuideView`, `LibraryView`, `AlbumDetailView`, `ArtistDetailView`, `PlaylistDetailView`, `LastFMView`, `MiniPlayerView`, `SongRow`, `CoverArtView`).
- `mix-analyzer/` — Script Python (`analyze_library.py`) para análise estrutural (`allin1` + `demucs`) e extração de vetor de Vibe 24D (`librosa`).

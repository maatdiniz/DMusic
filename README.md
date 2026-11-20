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
  - Medição rápida de RMS e Peak reais (`Accelerate/vDSP`) por faixa com 4 níveis nos Ajustes (*Desligada*, *Baixo `-16 dBFS`*, *Médio `-14 dBFS`*, *Alto `-11 dBFS`*) e proteção anti-clipping em `-0.5 dBFS`.
- **Offline Primeiro:** Downloads permanentes sem transcodificação, cache LRU configurável de faixas recentes e cache persistente de capas.
- **AirPlay Áudio, Bluetooth & Now Playing:** Integração completa com `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter` (Tela Bloqueada, AirPlay Áudio e Now Playing do CarPlay) e recuperação transparente em trocas de rota Bluetooth sem reiniciar a faixa.
- **Last.fm + Sanitização de Tags:** Autenticação nativa `auth.getMobileSession`, fila offline persistente, regra oficial de 50%/4 min e normalização avançada de tags (Unicode NFC, artista principal, remoção de sufixos de remaster/deluxe).

---

## Histórico de Versões

### v2.5 — Rebrand para DMusic, Compensação de Volume e Refinos de Mixagem
- **Identidade DMusic:** Renomeação do app e das referências internas para **DMusic**.
- **Compensação de Volume nos Ajustes:** Nivelamento automático entre faixas nos modos *Desligada*, *Baixo*, *Médio* e *Alto* com observações detalhadas por nível e proteção contra clipping.
- **Cabeçalho "Tocando de" mais limpo:** Design minimalista sem cápsula e suporte à origem **`TOCANDO DO MIX DE <faixa>`** ao iniciar um DJ Mix.
- **Botão Modo DJ integrado à Fila:** Menu rápido na Fila de Reprodução permitindo escolher entre *Nova ordenação inteligente*, *Continuar com a mesma fila* ou *Desativar Modo DJ*.
- **Saída em Passa-Alta com Volume Cheio:** Na curva *Sobrepor* com filtro Passa-Alta na saída, a faixa anterior mantém 100% de volume enquanto o filtro limpa a saída naturalmente.
- **Correção de Reconexão Bluetooth:** `AutomixAudioEngine` preserva o timestamp exato em trocas de rota (`AVAudioEngineConfigurationChange`), impedindo a faixa de reiniciar do zero.

### v2.4 — Smart Shuffle Consciente de Vibe & Timbre (24D)
- Extrator acústico de **24 dimensões** (`mix-analyzer/analyze_library.py --backfill-vibe`): 12 MFCCs, 4 bandas espectrais (Sub/Bass/Mid/High), razão harmônico/percussivo (HPSS), brilho, aspereza, contraste espectral e regularidade rítmica, com padronização Z-score + normalização L2.
- Integração de similaridade de Vibe no `SmartShuffler` e exibição da nota de Vibe (`V: XX%`) no log de diagnóstico.

### v2.3 — Design Unificado, Mix DJ Contextual e Roda de Camelot Suavizada
- Ajustes redesenhados no mesmo padrão visual escuro em cards da Fila de Reprodução.
- Opções de **Iniciar Mix DJ** (na lista/álbum/playlist atual ou com toda a biblioteca) direto no menu de contexto de qualquer faixa.
- MiniPlayer alinhado à identidade visual do app e tags Camelot padronizadas ao lado da duração com paleta suavizada sem borda.
- Limpeza de templates dedicados de CarPlay, mantendo compatibilidade universal via Now Playing nativo do iOS.

### v2.2 — Mesa DJ Visual, Beat-on-Beat e Biblioteca Estendida
- Palco visual `DJDualJogStageView` com animação de decks girando durante a transição, slider DJ com zona de BPM destacada e exibição de BPM ao vivo.
- Detecção de presença real de batida por compasso (`bar_beat` 35–175 Hz) para entradas *beat-on-beat* ou *vocal teaser → drop*.
- Suporte completo a bibliotecas longas (1.000+ faixas), correção de saltos de oitava/half-time e tela de diagnóstico (`AutomixLogsView`) + Estúdio Automix (`AutomixStudioSheet`).

### v2.1 — Arquitetura Sidecar (`allin1` + `librosa`) e Motor `AVAudioEngine` Dual-Deck
- Pipeline produtor-consumidor (`mix-analyzer/analyze_library.py`) com separação `demucs` (GPU MPS) + análise estrutural `allin1` (`intro`/`verse`/`chorus`/`outro`, beats e downbeats) + Camelot e energia via `librosa`.
- Servidor leve em FastAPI (`:4534`) para ingestão e cálculo de planos de transição `TransitionPlan` alinhados por fraseado (*Pair-Wise Phrase Matching*).
- Motor `AVAudioEngine` Dual-Deck com grafo fixo em 48 kHz Stereo (`DeckPCMStreamer` via `AVAudioConverter`), rampa de BPM, disparo ancorado em `AVAudioTime` e Bass Swap de `-24 dB`.

### v2.0 — Automix Local, `ArtistParser` e Redesign Visual
- Análise local via `Accelerate/vDSP` (`TrackAnalysisStore`) para BPM decimal, fase de batida e tonalidade Camelot.
- `ArtistParser` para separação automática de múltiplos artistas por vírgula, seletor individual de artista e discografia completa incluindo participações.
- Redesign do `NowPlayingView` com fundo *ambient blur*, título com *marquee* vai-e-volta estilo Spotify e cabeçalho contextual navegável.

### v1.5 — Last.fm, AirPlay Áudio, Downloads e Fila Interativa
- Integração completa com a API 2.0 do Last.fm (`LastFMClient`, `ScrobbleManager`, `ScrobbleTagSanitizer`) com fila offline persistente e prévia de tags ao vivo.
- Downloads permanentes offline (`DownloadManager`), cache LRU de músicas recentes (`RecentSongsCache`) e `QueueView` com reordenação por drag-and-drop.
- Reprodução *Gapless* (`AVQueuePlayer`), modo Aleatório com fila fixa, Sleep Timer e AirPlay estritamente como áudio.

### v1.0 — Base Hi-Res OpenSubsonic
- Cliente nativo SwiftUI Dark Mode conectado ao protocolo OpenSubsonic v1.16.1 (autenticação MD5+salt, Keychain, abas *Início*, *Biblioteca* e *Buscar*, badge Hi-Res, MiniPlayer, Background Audio e controles na Tela Bloqueada).

---

## Estrutura do Projeto

- `DMusic/Models/` — Modelos OpenSubsonic (`Song`, `Album`, `Artist`, `Playlist`, `PlaybackSource`) e modelos de mixagem (`TransitionPlan`, `CamelotKey`, `ServerTrackMixInfo`).
- `DMusic/Services/` — `SubsonicClient`, `AudioPlayerManager`, `AutomixAudioEngine`, `SmartShuffler`, `TrackAnalysisStore`, `MixServerClient`, `DownloadManager`, `RecentSongsCache`, `ImageCache`, `LastFMClient`, `ScrobbleManager`, `ArtistParser`, `CacheSettings`.
- `DMusic/ViewModels/` — `AuthViewModel`, `HomeViewModel`, `LibraryViewModel`, `SearchViewModel`.
- `DMusic/Views/` & `Components/` — Telas SwiftUI (`NowPlayingView`, `QueueView`, `SettingsView`, `LibraryView`, `AlbumDetailView`, `ArtistDetailView`, `PlaylistDetailView`, `LastFMView`, `MiniPlayerView`, `SongRow`, `CoverArtView`).
- `mix-analyzer/` — Script Python (`analyze_library.py`) para análise estrutural (`allin1` + `demucs`) e extração de vetor de Vibe 24D (`librosa`).

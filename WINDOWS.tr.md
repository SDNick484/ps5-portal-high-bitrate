# Windows 11 — yerel test paketi, henüz yayımlanmış sürüm değil

Windows desteği fiziksel cihazlarla henüz doğrulanmadı. GitHub'a release olarak yüklenmedi. macOS'ta geçen çevrimdışı testler Windows sürücüsü veya gerçek bağlantı testi yerine geçmez.

## 1. Kurulum

- ZIP'i Windows'a aktar, tamamen bir klasöre çıkar. ZIP'in içinden çalıştırma. Klasör yalnız güvendiğin kullanıcılar tarafından değiştirilebilsin.
- [Python](https://www.python.org/downloads/windows/) 3.10 veya üstü kurulu olsun; Python launcher (`py`) dahil olmalı. Python 3.12/3.13/3.14 kullanılabilir.
- [Npcap](https://npcap.com/#download) resmî yükleyicisini kur. Eski WinPcap yerine Npcap kullan. Wi-Fi monitor/raw 802.11 modu gerekmiyor; normal Ethernet görünümü kullanılacak. Sürücüyü bu pakete dahil etmiyoruz.
- `Setup-Windows.cmd` çift tıkla. Python ortamını kurar ve çevrimdışı testleri çalıştırır. Testler başarısızsa canlı denemeye geçme.
- Windows, Mac, PS5 ve Portal aynı yerel ağda olsun. PS5 Ethernet tercih edilir. Windows PC için de mümkünse Ethernet kullan; Wi-Fi sürücülerinde paket gönderme desteği değişebilir. USB gerekmez. Mac başlatıcısı aynı anda çalışmasın.

## 2. Adresleri ayarla ve kontrol et

- `Configure-Windows.cmd` üzerine sağ tık → **Yönetici olarak çalıştır**.
- İnternete/yerel ağa bağlı adaptör numarasını seç. VPN, loopback ve sanal adaptörü seçme.
- PS5 ve Portal'ın güncel IPv4 adreslerini gir. Adresleri cihazların ağ ekranından veya router uygulamasından öğren. Mac'in eski adreslerini varsayma.
- `Check-Windows.cmd` → **Yönetici olarak çalıştır**.
- `CHECK PASSED` bekle. Bu adım yalnız rota, IP forwarding, iki cihazın MAC adresleri ve Npcap erişimini kontrol eder; yönlendirme değiştirmez.
- Paylaşıma açık/hotspot/VPN veya IP yönlendirme etkin bir adaptörde program durabilir. Güvenlik duvarını kapatmanı istemiyoruz. Hata metnini paylaş.

## 3. Önce değişikliksiz bağlantı denemesi

- Portal'ın PS5 bağlantısını kes; PS5 açık kalsın.
- `Baseline-Windows.cmd` → **Yönetici olarak çalıştır**.
- Enter, ardından **READY / HAZIR** mesajından sonra Portal'dan PS5'e bağlan.
- Aktarma 40 saniyeyle sınırlı. PS5 kabulü + STREAMINFO, iki yönde paket aktarımı ve hatasız geri yükleme görülürse `Baseline passed` yazılır.
- Görüntü ve kontrolün normal kaldığını gözünle doğrula. Sonuçta `restoration_errors` boş olmalı.
- Başarılı baseline kaydı yoksa bitrate denemesi açılmaz. Başarılı kayıt gerçek gecikme/akıcılık ölçümü değildir.

## 4. Bitrate denemesi

- Yeni bağlantı için tekrar Portal'ın PS5 bağlantısını kes.
- `Start-Windows.cmd` → **Yönetici olarak çalıştır**.
- İlk Windows denemesinde **65** seç. Başarılı ve akıcıysa ayrı yeni bağlantılarda 100, sonra 200 denenebilir.
- Enter → **READY / HAZIR** → Portal'dan bağlan.
- `Startup packet modified` mesajını, ardından sonucu bekle.
- Ayrı Npcap yakalama tutamacı değiştirilen paketin yerel çıkışını doğrular. Ham paketler diske yazılmaz.
- Başarı: yeni başlangıç, kabul ve akış bilgisi sonrası üç yüksek hedef; ayrıca bağımsız yerel çıkış doğrulaması. Bunun dışında kod 1 dönebilir. 200 profilinin hedefi 158 Mbps civarında kalırsa üç kez 160 Mbps koşulu sağlanmaz; bu bağlantı başarısız demek değildir.
- İşlemden sonra PC aradan çıkar. Hedef sayı gerçek video hızı değildir. Portal'da gördüğün hız, çözünürlük ve takılma durumunu bildir.

## Geri dönüş / kurtarma

- Normal ayara dönmek için Portal bağlantısını kes, başlatıcı olmadan yeniden bağlan.
- Ctrl+C temizliği tetikler. Terminali kapatma, PC'yi uyutma veya kapatma yerine Ctrl+C kullan.
- Bağımsız kurtarma süreci hazır olduktan 50 saniye sonra, ana işlem çökmüş olsa da özgün ARP eşlemelerini göndermeyi dener. Windows routing, kayıt defteri veya firewall ayarı değiştirilmez.
- `restoration_errors` varsa bilgisayarı en az 60 saniye açık tut. Deneme klasöründeki `recovery-state.recovery.json` ve `watchdog.log` dosyalarını incele. Bilgisayar kapanırsa kurtarma çalışamaz.
- Aktif işlem/watchdog kalmadığında yönetici Terminal'de `".venv\Scripts\python.exe" portal_windows.py --restore "experiments\ILGILI-KLASOR\recovery-state.json"` ile yalnız programın ürettiği ilgili kaydı tekrar uygula. Başkasından gelen kurtarma dosyasını çalıştırma.
- Bağlantı hâlâ bozuksa PS5 ve Portal ağ bağlantılarını yeniden kurarak komşu adres eşlemelerini yenile.

## Paylaşılacak sonuç

Önce Check ve Baseline terminal çıktılarını gönder. Sonra profil testi sonucu: `counts`, `ps5_messages`, `high_target_confirmed`, `egress_witness`, `restoration_errors` ve Portal gözlemin. `config.windows.json`, `windows-baseline.json`, `recovery-state.json` özel ağ bilgisi içerir; public issue'ya yükleme. Paket içindeki gerçek IP'ler yalnız sen Windows'ta girince oluşur.

Teknik kaynaklar: [Scapy Windows kurulumu](https://scapy.readthedocs.io/en/stable/installation.html), [Npcap rehberi](https://npcap.com/guide/npcap-users-guide.html). Adaptör/sürücü uyumluluğu canlı test gerektirir.

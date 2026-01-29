# F5-BIG-IP-Let-s-Encrypt-Automation
F5 BIG-IP Let's Encrypt Automation

## **1\. Wstęp i Architektura**

Ten zestaw narzędzi zapewnia pełną automatyzację zarządzania certyfikatami SSL/TLS na platformie F5 BIG-IP przy użyciu darmowego urzędu certyfikacji Let's Encrypt. Rozwiązanie zostało zaprojektowane z myślą o specyficznych wymaganiach usług **APM (Access Policy Manager)** oraz nowoczesnych standardach bezpieczeństwa (**TLS 1.3**).

### **Kluczowe założenia architektoniczne:**

* **Klient ACME:** Skrypt wykorzystuje lekkiego klienta dehydrated (bash), co eliminuje konieczność instalowania Pythona czy zewnętrznych zależności na F5.  
* **Walidacja Domeny:** Odbywa się metodą HTTP-01. F5 wykorzystuje dedykowaną iRule oraz Data Group do dynamicznego serwowania tokenów walidacyjnych, bez potrzeby modyfikacji serwerów backendowych.  
* **Algorytm RSA 4096:** Wymuszony standard klucza. Jest to **krytyczne** dla usług APM publikujących zasoby RDP (Remote Desktop). F5 podpisuje pliki .rdp kluczem prywatnym VS-a. Algorytm ECC (domyślny w wielu klientach ACME) powoduje błędy podpisu i brak pobierania plików przez użytkownika.  
* **Bezpieczeństwo SSL:** Automatyczna konfiguracja profili Client-SSL z obsługą TLS 1.3 (poprzez cipher-group f5-default) oraz blokadą przestarzałych protokołów (SSLv3, TLS 1.0, TLS 1.1, DTLS).

## ---

**2\. Wymagania Wstępne**

Przed uruchomieniem skryptu upewnij się, że spełnione są następujące warunki:

1. **Virtual Server HTTP:** Musi istnieć VS nasłuchujący na porcie 80 (np. http-vs), dostępny publicznie dla domen, które chcesz certyfikować.  
   * *Uwaga:* Skrypt automatycznie podepnie do niego iRule walidacyjną.  
2. **DNS:** Domeny (np. vpn.firma.pl) muszą rozwiązywać się na publiczny adres IP tego Virtual Servera.  
3. **Łączność:** Urządzenie F5 (Management lub TMM routes) musi mieć wyjście do Internetu, aby połączyć się z API Let's Encrypt (acme-v02.api.letsencrypt.org).  
4. **Wersja TMOS:** Dla obsługi TLS 1.3 zalecana wersja 14.1 lub nowsza.

## ---

**3\. Instalacja i Konfiguracja**

### **Krok 1: Wdrożenie pliku**

Umieść skrypt f5-letsencrypt-rsa.sh w katalogu /shared/letsencrypt/ i nadaj mu uprawnienia:

Bash

chmod \+x /shared/letsencrypt/f5-letsencrypt-rsa.sh

### **Krok 2: Konfiguracja domen**

Edytuj skrypt, aby zdefiniować listę obsługiwanych domen:

Bash

nano /shared/letsencrypt/f5-letsencrypt-rsa.sh

Znajdź sekcję DOMAINS i wprowadź swoje wpisy:

Bash

readonly DOMAINS=(  
    "vpn.twoja-firma.pl"  
    "poczta.twoja-firma.pl"  
)

### **Krok 3: Inicjalizacja środowiska (install)**

To polecenie przygotowuje grunt pod działanie automatyzacji.

Bash

./f5-letsencrypt-rsa.sh install

**Co robi ta komenda?**

1. Tworzy strukturę katalogów (certs, accounts, config).  
2. Pobiera klienta dehydrated oraz certyfikaty Root CA Let's Encrypt.  
3. Generuje plik konfiguracyjny wymuszający **RSA 4096**.  
4. Tworzy obiekty F5:  
   * **Data Group:** dg\_acme\_challenges (baza danych tokenów).  
   * **iRule:** irule\_acme\_handler (logika obsługi zapytań HTTP).  
   * Przypina iRule do wskazanego VS-a (http-vs).  
5. Rejestruje konto w Let's Encrypt i akceptuje regulamin.  
6. Konfiguruje **iCall** (wewnętrzny cron F5) do automatycznego odnawiania co 7 dni.

## ---

**4\. Zarządzanie Certyfikatami**

### **Generowanie / Odnawianie (issue)**

To jest główna komenda operacyjna. Uruchom ją po instalacji lub dodaniu nowej domeny.

Bash

./f5-letsencrypt-rsa.sh issue

**Proces działania:**

1. Skrypt sprawdza ważność certyfikatów dla każdej domeny.  
2. Jeśli certyfikat wygasa za \< 30 dni (lub go brak):  
   * Pobiera wyzwanie (challenge) z Let's Encrypt.  
   * Wgrywa token do Data Group na F5.  
   * Czeka na weryfikację przez serwery Let's Encrypt.  
   * Pobiera nowy certyfikat i klucz.  
   * Instaluje obiekty sys crypto key i sys crypto cert w systemie F5.  
   * **Automatycznie tworzy lub aktualizuje** profil ltm profile client-ssl.

### **Aktualizacja Profili SSL bez Odnawiania (update-profiles)**

Użyj tej opcji, jeśli masz już ważne certyfikaty, ale chcesz zmienić ustawienia bezpieczeństwa (np. włączyć TLS 1.3 na istniejących profilach).

Bash

./f5-letsencrypt-rsa.sh update-profiles

**Działanie:**

* Iteruje przez wszystkie domeny.  
* Znajduje odpowiadające im profile Client-SSL (cssl\_domena...).  
* Wymusza ustawienia: ciphers none, cipher-group f5-default, options { ... }.  
* Nie dotyka kluczy ani certyfikatów.

### **Reset Certyfikatów (reset-certs)**

Krytyczna opcja przy migracji lub naprawie błędów.

Bash

./f5-letsencrypt-rsa.sh reset-certs

**Kiedy stosować?**

* Gdy zmieniasz algorytm z ECC na RSA (aby wymusić wygenerowanie nowych kluczy).  
* Gdy chcesz wymusić natychmiastowe odnowienie wszystkich certyfikatów, nawet jeśli są ważne.  
* *Uwaga:* Po wykonaniu tej komendy musisz uruchomić issue, aby pobrać nowe certyfikaty.

## ---

**5\. Integracja z Virtual Servers (Produkcja)**

Skrypt tworzy profile SSL, ale nie przypina ich automatycznie do produkcyjnych VS-ów (np. 443), aby uniknąć niezamierzonych przerw w działaniu.

**Jednorazowa konfiguracja:**

1. Zaloguj się do GUI.  
2. Wejdź w **Local Traffic ›› Virtual Servers**.  
3. Edytuj swój docelowy VS (np. vs\_vpn\_443).  
4. W sekcji **SSL Profile (Client)** przenieś do okna "Selected" profil utworzony przez skrypt.  
   * Nazwa profilu: cssl\_\<nazwa\_domeny\_z\_kropkami\_zamienionymi\_na\_podkreslniki\>  
   * Przykład: cssl\_vpn\_twoja\_firma\_pl  
5. Zapisz (Update).

Od tego momentu **nie musisz robić nic więcej**. Gdy skrypt odnowi certyfikat (co 60 dni), zaktualizuje on ten profil "w locie", a VS natychmiast zacznie serwować nowy certyfikat.

## ---

**6\. Rozwiązywanie Problemów (Troubleshooting)**

| Problem | Diagnoza | Rozwiązanie |
| :---- | :---- | :---- |
| **RDP w APM nie pobiera się** | Prawdopodobnie używasz certyfikatu ECC (domyślnego) zamiast RSA. | Wykonaj: install (aby wgrać config RSA), potem reset-certs i issue. Sprawdź w GUI czy certyfikat ma algorytm RSA. |
| **Błąd walidacji (404/Connection Refused)** | iRule nie działa lub VS jest niedostępny. | Sprawdź show-irule. Upewnij się, że port 80 jest otwarty na firewallu dla świata. |
| **Błąd "Is a directory"** | Stary błąd skryptu v1. | Uruchom install (v5 automatycznie to naprawia). |
| **Brak TLS 1.3** | Stara wersja TMOS lub profil. | Upewnij się, że masz TMOS v14+. Uruchom update-profiles. |

### **Przydatne polecenia diagnostyczne**

**Podgląd logów:**

Bash

tail \-f /var/log/letsencrypt.log

**Sprawdzenie iRule:**

Bash

./f5-letsencrypt-rsa.sh show-irule

**Sprawdzenie harmonogramu automatyzacji:**

Bash

tmsh list sys icall handler periodic letse\_renew\_handler

## ---

**7\. Podsumowanie Opcji Skryptu**

| Komenda | Opis | Bezpieczeństwo |
| :---- | :---- | :---- |
| install | Inicjalizacja środowiska. Naprawia błędy, wgrywa iRule, konfiguruje RSA. | Bezpieczne (nie przerywa ruchu). |
| issue | Główna procedura. Pobiera i instaluje certyfikaty. | Bezpieczne (podmienia certyfikaty atomowo). |
| update-profiles | Aktualizuje tylko ustawienia szyfrowania (TLS 1.3). | Bezpieczne (powoduje re-handshake SSL). |
| reset-certs | Usuwa pliki z dysku. | **Uwaga:** Wymaga ponownego issue. |
| show-irule | Wyświetla kod iRule. | Tylko odczyt. |


//+------------------------------------------------------------------+
//| SyncHistory.mq5 - force-download XAUUSD M1 history, report count |
//| Runs once from the GitHub Actions runner (terminal64 /config).    |
//| Writes MQL5\Files\sync-result.txt in the terminal data folder.   |
//| Window covers the default backtest window 2026.08.03-2026.10.16.  |
//| CopyRates blocks until the terminal has the data (or retries).    |
//+------------------------------------------------------------------+
#property copyright "ikilledfms - research build for Prince"
#property version   "1.00"

input string   InpSymbol = "XAUUSD";
input datetime InpFrom    = D'2026.08.01 00:00';
input datetime InpTo      = D'2026.10.19 23:59';

void OnStart()
{
   MqlRates rates[];
   int copied = 0;
   int connected = 0;
   for(int attempt = 0; attempt < 30; attempt++)
   {
      connected = (int)TerminalInfoInteger(TERMINAL_CONNECTED);
      copied = CopyRates(InpSymbol, PERIOD_M1, InpFrom, InpTo, rates);
      PrintFormat("SyncHistory attempt %d: connected=%d M1 bars=%d", attempt, connected, copied);
      if(copied > 0)
         break;
      Sleep(10000);
   }
   int handle = FileOpen("sync-result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      FileWriteString(handle, StringFormat("SYMBOL=%s\nM1_BARS=%d\nTERMINAL_CONNECTED=%d\n", InpSymbol, copied, connected));
      FileClose(handle);
   }
   PrintFormat("SyncHistory done: %s M1 bars=%d connected=%d", InpSymbol, copied, connected);
}

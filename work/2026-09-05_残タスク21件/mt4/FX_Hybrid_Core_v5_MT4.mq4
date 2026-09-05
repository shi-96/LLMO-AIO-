//+------------------------------------------------------------------+
//|                                     FX_Hybrid_Core_v5_MT4.mq4    |
//|  FX Hybrid v5（MT5版）の採用構成を MT4 / MQL4 へ移植したもの     |
//|                                                                  |
//|  移植元: FX_Hybrid_Core_v5_FINAL.mq5                             |
//|  採用構成: 132コア(TomCamp SMC) + 出来高デルタSOFT               |
//|            M15 / RR2.0 / NYセッションのみ(GMT 13-16)             |
//|            1トレード0.5% / 同時保有1                             |
//|                                                                  |
//|  ★重要★ 本ファイルは MT5版の納品資料に記載された仕様から        |
//|  再構成したものです。MT5版ソース(.mq5)と1行単位で突き合わせた    |
//|  差分検証は未実施です。実弾投入の前に必ず                        |
//|  「MT4移植_未検証項目リスト」を読んでください。                  |
//+------------------------------------------------------------------+
#property strict
#property description "FX Hybrid v5 MT4移植版 / NYセッション限定 / M15 / RR2.0"

//--- 使う機能 -------------------------------------------------------
input bool   Enable_Core132     = true;   // 132コア（TomCamp SMC）を使う
input int    BVD_For_Core132    = 1;      // 出来高デルタ 0=OFF 1=SOFT 2=HARD
input bool   Enable_ExecGuards  = true;   // 執行時の安全策を使う

//--- 時間帯（GMT） --------------------------------------------------
input int    LondonStart        = 0;      // ロンドン開始（0/0で不使用）
input int    LondonEnd          = 0;      // ロンドン終了
input int    NYStart            = 13;     // ニューヨーク開始（GMT）
input int    NYEnd              = 16;     // ニューヨーク終了（GMT）

//--- 損益の決め方 ---------------------------------------------------
input double TP_RR              = 2.0;    // 利確＝リスクの何倍か
input double RiskPct            = 0.5;    // 1トレードの許容損失（有効証拠金比 %）
input int    SL_Buffer_Pt       = 150;    // 損切りに足すバッファ（point）
input int    MaxPosition        = 1;      // 同時保有の上限

//--- 構造検出 -------------------------------------------------------
input int    StructureLook      = 20;     // 構造検出の参照本数
input int    OB_Bars            = 3;      // オーダーブロック検出の参照本数

//--- 出来高デルタ ---------------------------------------------------
input double BVD_DeltaFull      = 0.70;   // フルサイズの境目
input double BVD_DeltaHalf      = 0.55;   // 半サイズの境目
input double BVD_SoftLotRatio   = 0.5;    // 半サイズ時の倍率
input int    BVD_M1Bars         = 8;      // 出来高デルタの参照本数（M1）

//--- 使わない機能（すべてOFF） -------------------------------------
input bool   Enable_Trend151    = false;  // 151ロジック
input bool   Enable_ATRTrailing = false;  // ATRトレーリング
input bool   Enable_Pyramid     = false;  // 建て増し
input bool   Enable_PartialExit = false;  // 部分決済
input bool   Enable_RegimeRouter= false;  // 局面ルーター
input int    TrailMode          = 0;      // 追従決済
input int    EarlyExit_Bars     = 0;      // 早期撤退
input int    DistanceMode       = 0;      // 0=固定point 1=ATR連動
input int    ExitMode           = 0;      // 0=RR固定

//--- 執行 -----------------------------------------------------------
input int    MagicNumber        = 20260905;
input int    SlippagePt         = 30;
input int    MinBarsRequired    = 300;    // M15の必要本数
input bool   VerboseLog         = true;

//--- 内部状態 -------------------------------------------------------
datetime g_lastBarTime = 0;   // 同一バー重複発注の防止

//+------------------------------------------------------------------+
int OnInit()
  {
   if(Period() != PERIOD_M15)
      Print("[警告] 採用構成はM15です。現在の時間足=", Period(), "分");
   if(Digits <= 0)
      return(INIT_FAILED);
   Print("FX Hybrid v5 MT4移植版 起動 / 銘柄=", Symbol(),
         " / NY(GMT)=", NYStart, "-", NYEnd,
         " / RiskPct=", DoubleToString(RiskPct,2),
         " / TP_RR=", DoubleToString(TP_RR,2));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
//| 判定はすべて確定足（index>=1）で行う。未来参照はしない            |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!Enable_Core132) return;

   // --- 同一バー重複発注の防止 ---
   datetime bt = Time[0];
   if(bt == g_lastBarTime) return;

   // --- 執行安全策 ---
   if(Enable_ExecGuards && !ExecGuardsPass()) { g_lastBarTime = bt; return; }

   // --- 同時保有の上限 ---
   if(CountOwnPositions() >= MaxPosition) { g_lastBarTime = bt; return; }

   // --- 時間帯（GMT）---
   if(!InTradingSession()) { g_lastBarTime = bt; return; }

   // --- 132コアのシグナル判定 ---
   int dir = Core132Signal();          // +1=買い -1=売り 0=なし
   if(dir == 0) { g_lastBarTime = bt; return; }

   // --- 出来高デルタ（SOFT）でロット倍率を決める ---
   double lotRatio = 1.0;
   if(BVD_For_Core132 > 0)
     {
      double delta = VolumeDelta();
      if(delta >= BVD_DeltaFull)       lotRatio = 1.0;
      else if(delta >= BVD_DeltaHalf)  lotRatio = (BVD_For_Core132 == 1 ? BVD_SoftLotRatio : 0.0);
      else                             lotRatio = 0.0;   // 極端に弱い時は見送り
      if(lotRatio <= 0.0)
        {
         if(VerboseLog) Print("[見送り] 出来高デルタが弱い delta=", DoubleToString(delta,3));
         g_lastBarTime = bt; return;
        }
     }

   // --- SL / TP を決める ---
   double sl = 0, tp = 0, entry = 0;
   if(!BuildLevels(dir, entry, sl, tp)) { g_lastBarTime = bt; return; }

   // --- ロット計算（有効証拠金ベース）---
   double lots = CalcLots(entry, sl) * lotRatio;
   lots = NormalizeLots(lots);
   if(lots <= 0.0) { g_lastBarTime = bt; return; }

   SendOrder(dir, lots, sl, tp);
   g_lastBarTime = bt;
  }

//+------------------------------------------------------------------+
//| 132コア（TomCamp SMC キルゾーン）のシグナル                       |
//|  ・構造の切り上げ／切り下げ（StructureLook本）                    |
//|  ・直近OB_Bars本のオーダーブロックへの回帰                        |
//|  ・EMAの向きで方向を確定                                          |
//|  判定は close[1] / close[2] / EMA[1] の確定足のみを使う           |
//+------------------------------------------------------------------+
int Core132Signal()
  {
   if(Bars < StructureLook + OB_Bars + 5) return(0);

   double ema1 = iMA(Symbol(), 0, 50, 0, MODE_EMA, PRICE_CLOSE, 1);
   double c1   = Close[1];
   double c2   = Close[2];

   // 構造：直近StructureLook本（確定足のみ）の高値・安値
   int    hiIdx = iHighest(Symbol(), 0, MODE_HIGH, StructureLook, 1);
   int    loIdx = iLowest (Symbol(), 0, MODE_LOW , StructureLook, 1);
   double swingHigh = High[hiIdx];
   double swingLow  = Low [loIdx];

   // オーダーブロック：直近OB_Bars本の実体レンジ
   double obHigh = -DBL_MAX, obLow = DBL_MAX;
   for(int i = 1; i <= OB_Bars; i++)
     {
      double bodyHi = MathMax(Open[i], Close[i]);
      double bodyLo = MathMin(Open[i], Close[i]);
      if(bodyHi > obHigh) obHigh = bodyHi;
      if(bodyLo < obLow ) obLow  = bodyLo;
     }

   // 買い：構造の高値を上抜け（BOS）かつEMAより上、かつOB上限へ回帰
   bool bosUp   = (c1 > swingHigh) && (c2 <= swingHigh);
   bool bosDown = (c1 < swingLow ) && (c2 >= swingLow );

   if(bosUp   && c1 > ema1 && c1 >= obLow ) return(+1);
   if(bosDown && c1 < ema1 && c1 <= obHigh) return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| 出来高デルタ（ティック出来高による近似）                          |
//|  FX/CFDには板情報が無いため、これは真の出来高デルタではない。     |
//|  ブローカー依存の指標であり、業者が変われば値も変わる。           |
//|  index 0 は形成中のM1足だが、判定時点で入手できる情報しか見ない。 |
//+------------------------------------------------------------------+
double VolumeDelta()
  {
   double up = 0, dn = 0;
   for(int i = 0; i < BVD_M1Bars; i++)
     {
      double v = (double)iVolume(Symbol(), PERIOD_M1, i);
      double o = iOpen (Symbol(), PERIOD_M1, i);
      double c = iClose(Symbol(), PERIOD_M1, i);
      if(c >= o) up += v; else dn += v;
     }
   double tot = up + dn;
   if(tot <= 0.0) return(0.0);
   return(MathMax(up, dn) / tot);   // 0.5=拮抗 1.0=一方向
  }

//+------------------------------------------------------------------+
//| 時間帯（GMT基準）。MT4のTimeGMT()を使う                           |
//+------------------------------------------------------------------+
bool InTradingSession()
  {
   datetime g = TimeGMT();
   int hour = TimeHour(g);
   bool inNY = (NYEnd > NYStart) && (hour >= NYStart && hour < NYEnd);
   bool inLD = (LondonEnd > LondonStart) && (hour >= LondonStart && hour < LondonEnd);
   return(inNY || inLD);
  }

//+------------------------------------------------------------------+
//| SL / TP を決める（DistanceMode=0 固定point）                      |
//+------------------------------------------------------------------+
bool BuildLevels(int dir, double &entry, double &sl, double &tp)
  {
   RefreshRates();
   double buf = SL_Buffer_Pt * Point;

   int hiIdx = iHighest(Symbol(), 0, MODE_HIGH, StructureLook, 1);
   int loIdx = iLowest (Symbol(), 0, MODE_LOW , StructureLook, 1);

   if(dir > 0)
     {
      entry = Ask;
      sl    = Low[loIdx] - buf;
      if(sl >= entry) return(false);
      tp    = entry + (entry - sl) * TP_RR;
     }
   else
     {
      entry = Bid;
      sl    = High[hiIdx] + buf;
      if(sl <= entry) return(false);
      tp    = entry - (sl - entry) * TP_RR;
     }

   // ストップレベル／フリーズレベルの外側へ押し出す（invalid stops対策）
   double stopLvl   = MarketInfo(Symbol(), MODE_STOPLEVEL)  * Point;
   double freezeLvl = MarketInfo(Symbol(), MODE_FREEZELEVEL)* Point;
   double minDist   = MathMax(stopLvl, freezeLvl);

   if(dir > 0)
     {
      if(entry - sl < minDist) sl = entry - minDist;
      if(tp - entry < minDist) tp = entry + minDist;
     }
   else
     {
      if(sl - entry < minDist) sl = entry + minDist;
      if(entry - tp < minDist) tp = entry - minDist;
     }

   sl = NormalizeDouble(sl, Digits);
   tp = NormalizeDouble(tp, Digits);
   return(true);
  }

//+------------------------------------------------------------------+
//| ロット計算（有効証拠金ベース・1トレードRiskPct%）                 |
//+------------------------------------------------------------------+
double CalcLots(double entry, double sl)
  {
   double equity   = AccountEquity();
   double riskCash = equity * RiskPct / 100.0;

   double tickVal  = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tickSize <= 0.0 || tickVal <= 0.0) return(0.0);

   double dist = MathAbs(entry - sl);
   if(dist <= 0.0) return(0.0);

   double lossPerLot = (dist / tickSize) * tickVal;
   if(lossPerLot <= 0.0) return(0.0);

   return(riskCash / lossPerLot);
  }

//+------------------------------------------------------------------+
//| 数量の正規化（最小・最大・刻み幅）                                |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double minL  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxL  = MarketInfo(Symbol(), MODE_MAXLOT);
   double step  = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0.0) step = 0.01;

   lots = MathFloor(lots / step) * step;
   if(lots < minL) return(0.0);          // 最小に満たなければ発注しない
   if(lots > maxL) lots = maxL;
   return(NormalizeDouble(lots, 2));
  }

//+------------------------------------------------------------------+
//| 執行安全策                                                        |
//+------------------------------------------------------------------+
bool ExecGuardsPass()
  {
   // 履歴不足の確認
   if(Bars < MinBarsRequired)
     {
      if(VerboseLog) Print("[見送り] M15の履歴が不足 Bars=", Bars);
      return(false);
     }
   // 取引モードの確認（取引禁止・決済のみ）
   if(!IsTradeAllowed())
     {
      if(VerboseLog) Print("[見送り] 取引が許可されていない");
      return(false);
     }
   if(IsTradeContextBusy())
     {
      if(VerboseLog) Print("[見送り] 取引コンテキストが使用中");
      return(false);
     }
   // 気配値の異常確認
   RefreshRates();
   if(Ask <= 0.0 || Bid <= 0.0 || Ask <= Bid)
     {
      if(VerboseLog) Print("[見送り] 気配値が異常 Bid=", Bid, " Ask=", Ask);
      return(false);
     }
   // 銘柄の取引可否
   if(MarketInfo(Symbol(), MODE_TRADEALLOWED) == 0)
     {
      if(VerboseLog) Print("[見送り] この銘柄は現在取引できない");
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
int CountOwnPositions()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol())      continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() == OP_BUY || OrderType() == OP_SELL) n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
void SendOrder(int dir, double lots, double sl, double tp)
  {
   RefreshRates();
   int    type  = (dir > 0 ? OP_BUY : OP_SELL);
   double price = (dir > 0 ? Ask : Bid);

   int ticket = OrderSend(Symbol(), type, lots, NormalizeDouble(price, Digits),
                          SlippagePt, sl, tp,
                          "FXHybrid_v5_MT4", MagicNumber, 0,
                          (dir > 0 ? clrDodgerBlue : clrOrangeRed));
   if(ticket < 0)
      Print("[発注失敗] code=", GetLastError(),
            " type=", type, " lots=", DoubleToString(lots,2),
            " price=", DoubleToString(price,Digits),
            " sl=", DoubleToString(sl,Digits),
            " tp=", DoubleToString(tp,Digits));
   else if(VerboseLog)
      Print("[発注] ticket=", ticket, " ", (dir>0?"BUY":"SELL"),
            " lots=", DoubleToString(lots,2),
            " sl=", DoubleToString(sl,Digits),
            " tp=", DoubleToString(tp,Digits));
  }
//+------------------------------------------------------------------+

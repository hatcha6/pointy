/*
 * Copyright (C) 2017, David PHAM-VAN <dev.nfet.net@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "print_job.h"

#include "printing.h"

#include <fpdfview.h>
#include <objbase.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <tchar.h>
#include <codecvt>
#include <fstream>
#include <iterator>
#include <numeric>

namespace nfet {

const auto pdfDpi = 72;

std::string toUtf8(std::wstring wstr) {
  int cbMultiByte = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, nullptr,
                                        0, nullptr, nullptr);
  LPSTR lpMultiByteStr = (LPSTR)malloc(cbMultiByte);
  cbMultiByte =
      WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, lpMultiByteStr,
                          cbMultiByte, nullptr, nullptr);
  std::string ret = lpMultiByteStr;
  free(lpMultiByteStr);
  return ret;
}

std::string toUtf8(TCHAR* tstr) {
#ifndef UNICODE
#error "Non unicode build not supported"
#endif

  if (!tstr) {
    return std::string{};
  }

  return toUtf8(std::wstring{tstr});
}

std::wstring fromUtf8(std::string str) {
  auto len = MultiByteToWideChar(CP_UTF8, 0, str.c_str(),
                                 static_cast<int>(str.length()), nullptr, 0);
  if (len <= 0) {
    return L"";
  }

  auto wstr = std::wstring{};
  wstr.resize(len);
  MultiByteToWideChar(CP_UTF8, 0, str.c_str(), static_cast<int>(str.length()),
                      &wstr[0], len);

  return wstr;
}

PrintJob::PrintJob(Printing* printing, int index)
    : printing{printing}, index{index} {}

// POINTY PATCH (see POINTY_PATCHES.md): the settings a job that states its
// own page prints with — the driver's own settings for [printer], with only
// the paper replaced and then handed back to the driver to validate.
//
// Upstream allocated this DEVMODE, zeroed only its public part, and told the
// driver it carried DC_EXTRA bytes of private settings: uninitialised memory.
// A driver that keeps its media type, gap sensing or print mode in that
// private section can refuse such a job or stop the printer, and Windows then
// holds every later job behind it. Starting from what the driver itself
// reports keeps the shop's driver setup and changes only the paper.
//
// Null when the driver will not describe itself.
static DEVMODE* driverDevModeForPaper(const std::wstring& printer,
                                      short orientation,
                                      short paperWidth,
                                      short paperLength) {
  auto printerName = const_cast<LPWSTR>(printer.c_str());
  HANDLE handle = nullptr;
  if (!OpenPrinter(printerName, &handle, nullptr)) {
    return nullptr;
  }
  DEVMODE* dm = nullptr;
  const LONG needed =
      DocumentProperties(nullptr, handle, printerName, nullptr, nullptr, 0);
  if (needed > 0) {
    dm = static_cast<DEVMODE*>(GlobalAlloc(GPTR, static_cast<SIZE_T>(needed)));
  }
  if (dm != nullptr &&
      DocumentProperties(nullptr, handle, printerName, dm, nullptr,
                         DM_OUT_BUFFER) == IDOK) {
    dm->dmFields |=
        DM_ORIENTATION | DM_PAPERSIZE | DM_PAPERLENGTH | DM_PAPERWIDTH;
    dm->dmPaperSize = 0;
    dm->dmOrientation = orientation;
    dm->dmPaperWidth = paperWidth;
    dm->dmPaperLength = paperLength;
    if (DocumentProperties(nullptr, handle, printerName, dm, dm,
                           DM_IN_BUFFER | DM_OUT_BUFFER) != IDOK) {
      GlobalFree(dm);
      dm = nullptr;
    }
  } else if (dm != nullptr) {
    GlobalFree(dm);
    dm = nullptr;
  }
  ClosePrinter(handle);
  return dm;
}

bool PrintJob::printPdf(const std::string& name,
                        std::string printer,
                        double width,
                        double height,
                        bool usePrinterSettings) {
  documentName = name;

  // Null to use the driver's own settings as they stand.
  DEVMODE* dm = nullptr;

  if (!usePrinterSettings) {
    const bool landscape = width > height;
    const auto orientation =
        static_cast<short>(landscape ? DMORIENT_LANDSCAPE : DMORIENT_PORTRAIT);
    const auto paperWidth =
        static_cast<short>(round((landscape ? height : width) * 254 / pdfDpi));
    const auto paperLength =
        static_cast<short>(round((landscape ? width : height) * 254 / pdfDpi));
    if (!printer.empty()) {
      dm = driverDevModeForPaper(fromUtf8(printer), orientation, paperWidth,
                                 paperLength);
    }
    if (dm == nullptr) {
      // Nothing to start from: only the paper, with no private section, and
      // zeroed whole so no stray bytes reach the driver.
      dm = static_cast<DEVMODE*>(GlobalAlloc(GPTR, sizeof(DEVMODE)));
      if (dm != nullptr) {
        dm->dmSpecVersion = DM_SPECVERSION;
        dm->dmSize = static_cast<WORD>(sizeof(DEVMODE));
        dm->dmFields =
            DM_ORIENTATION | DM_PAPERSIZE | DM_PAPERLENGTH | DM_PAPERWIDTH;
        dm->dmPaperSize = 0;
        dm->dmOrientation = orientation;
        dm->dmPaperWidth = paperWidth;
        dm->dmPaperLength = paperLength;
      }
    }
  }

  if (printer.empty()) {
    PRINTDLG pd;

    // Initialize PRINTDLG
    ZeroMemory(&pd, sizeof(pd));
    pd.lStructSize = sizeof(pd);

    // POINTY PATCH: owned by the window the print came from. Without an
    // owner the dialog opens behind a full-screen till, shows only in the
    // taskbar, and the print waits on it.
    pd.hwndOwner = GetActiveWindow();
    pd.hDevMode = dm;
    pd.hDevNames = nullptr;  // Don't forget to free or store hDevNames.
    pd.hDC = nullptr;
    pd.Flags = PD_USEDEVMODECOPIES | PD_RETURNDC | PD_PRINTSETUP |
               PD_NOSELECTION | PD_NOPAGENUMS;
    pd.nCopies = 1;
    pd.nFromPage = 0xFFFF;
    pd.nToPage = 0xFFFF;
    pd.nMinPage = 1;
    pd.nMaxPage = 0xFFFF;

    auto r = PrintDlg(&pd);

    if (r != 1) {
      printing->onCompleted(this, false, "");
      if (pd.hDC) {
        DeleteDC(pd.hDC);
      }
      if (pd.hDevNames) {
        GlobalFree(pd.hDevNames);
      }
      if (pd.hDevMode) {
        GlobalFree(pd.hDevMode);
      }
      return true;
    }

    hDC = pd.hDC;
    hDevMode = pd.hDevMode;
    hDevNames = pd.hDevNames;

  } else {
    hDC = CreateDC(TEXT("WINSPOOL"), fromUtf8(printer).c_str(), nullptr, dm);
    if (!hDC) {
      if (dm != nullptr) {
        GlobalFree(dm);
      }
      // POINTY PATCH: answer the print. Dart waits for this job to complete,
      // and without a reply the call never returns.
      printing->onCompleted(this, false, "Unable to open the printer");
      return false;
    }
    hDevMode = dm;
    hDevNames = nullptr;
  }

  auto dpiX = static_cast<double>(GetDeviceCaps(hDC, LOGPIXELSX)) / pdfDpi;
  auto dpiY = static_cast<double>(GetDeviceCaps(hDC, LOGPIXELSY)) / pdfDpi;
  auto pageWidth =
      static_cast<double>(GetDeviceCaps(hDC, PHYSICALWIDTH)) / dpiX;
  auto pageHeight =
      static_cast<double>(GetDeviceCaps(hDC, PHYSICALHEIGHT)) / dpiY;
  auto printableWidth = static_cast<double>(GetDeviceCaps(hDC, HORZRES)) / dpiX;
  auto printableHeight =
      static_cast<double>(GetDeviceCaps(hDC, VERTRES)) / dpiY;
  auto marginLeft =
      static_cast<double>(GetDeviceCaps(hDC, PHYSICALOFFSETX)) / dpiX;
  auto marginTop =
      static_cast<double>(GetDeviceCaps(hDC, PHYSICALOFFSETY)) / dpiY;
  auto marginRight = pageWidth - printableWidth - marginLeft;
  auto marginBottom = pageHeight - printableHeight - marginTop;

  printing->onLayout(this, pageWidth, pageHeight, marginLeft, marginTop,
                     marginRight, marginBottom);
  return true;
}

std::vector<Printer> PrintJob::listPrinters() {
  LPTSTR defaultPrinter;
  DWORD size = 0;
  GetDefaultPrinter(nullptr, &size);

  defaultPrinter = static_cast<LPTSTR>(malloc(size * sizeof(TCHAR)));
  if (!GetDefaultPrinter(defaultPrinter, &size)) {
    size = 0;
  }

  auto printers = std::vector<Printer>{};
  DWORD needed = 0;
  DWORD returned = 0;
  const auto flags = PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS;

  EnumPrinters(flags, nullptr, 2, nullptr, 0, &needed, &returned);

  auto buffer = (PRINTER_INFO_2*)malloc(needed);
  if (!buffer) {
    return printers;
  }

  auto result = EnumPrinters(flags, nullptr, 2, (LPBYTE)buffer, needed, &needed,
                             &returned);

  if (result == 0) {
    free(buffer);
    return printers;
  }

  for (DWORD i = 0; i < returned; i++) {
    printers.push_back(Printer{
        toUtf8(buffer[i].pPrinterName), toUtf8(buffer[i].pPrinterName),
        toUtf8(buffer[i].pDriverName), toUtf8(buffer[i].pLocation),
        toUtf8(buffer[i].pComment),
        size > 0 && _tcsncmp(buffer[i].pPrinterName, defaultPrinter, size) == 0,
        (buffer[i].Status &
         (PRINTER_STATUS_NOT_AVAILABLE | PRINTER_STATUS_ERROR |
          PRINTER_STATUS_OFFLINE | PRINTER_STATUS_PAUSED)) == 0});
  }

  free(buffer);
  free(defaultPrinter);
  return printers;
}

void PrintJob::writeJob(std::vector<uint8_t> data) {
  auto dpiX = static_cast<double>(GetDeviceCaps(hDC, LOGPIXELSX)) / pdfDpi;
  auto dpiY = static_cast<double>(GetDeviceCaps(hDC, LOGPIXELSY)) / pdfDpi;

  DOCINFO docInfo;

  ZeroMemory(&docInfo, sizeof(docInfo));
  docInfo.cbSize = sizeof(docInfo);

  auto docName = fromUtf8(documentName);
  docInfo.lpszDocName = docName.c_str();

  FPDF_LIBRARY_CONFIG config;
  config.version = 2;
  config.m_pUserFontPaths = nullptr;
  config.m_pIsolate = nullptr;
  config.m_v8EmbedderSlot = 0;
  FPDF_InitLibraryWithConfig(&config);

  // POINTY PATCH: read the document before opening a job for it. Upstream
  // opened the job first and, on a document PDFium could not read, returned
  // with the job still open in the Windows queue — where it blocks every job
  // behind it — and never answered the print.
  auto doc = FPDF_LoadMemDocument64(data.data(), data.size(), nullptr);
  if (!doc) {
    FPDF_DestroyLibrary();
    DeleteDC(hDC);
    GlobalFree(hDevNames);
    GlobalFree(hDevMode);
    printing->onCompleted(this, false, "Unable to read the document");
    return;
  }

  auto r = StartDoc(hDC, &docInfo);
  if (r <= 0) {
    FPDF_CloseDocument(doc);
    FPDF_DestroyLibrary();
    DeleteDC(hDC);
    GlobalFree(hDevNames);
    GlobalFree(hDevMode);
    printing->onCompleted(this, false, "The printer did not accept the job");
    return;
  }

  auto pages = FPDF_GetPageCount(doc);
  auto marginLeft = GetDeviceCaps(hDC, PHYSICALOFFSETX);
  auto marginTop = GetDeviceCaps(hDC, PHYSICALOFFSETY);

  for (auto pageNum = 0; pageNum < pages; pageNum++) {
    StartPage(hDC);

    auto page = FPDF_LoadPage(doc, pageNum);
    if (!page) {
      EndPage(hDC);
      continue;
    }

    auto pdfWidth = FPDF_GetPageWidth(page);
    auto pdfHeight = FPDF_GetPageHeight(page);

    int bWidth = static_cast<int>(pdfWidth * dpiX);
    int bHeight = static_cast<int>(pdfHeight * dpiY);

    FPDF_RenderPage(hDC, page, -marginLeft, -marginTop, bWidth, bHeight, 0,
                    FPDF_ANNOT | FPDF_PRINTING);
    FPDF_ClosePage(page);
    r = EndPage(hDC);
  }

  FPDF_CloseDocument(doc);
  FPDF_DestroyLibrary();

  EndDoc(hDC);

  DeleteDC(hDC);
  GlobalFree(hDevNames);
  // POINTY PATCH: a DEVMODE is memory, not a printer handle.
  GlobalFree(hDevMode);

  printing->onCompleted(this, true, "");
}

void PrintJob::cancelJob(const std::string& error) {}

bool PrintJob::sharePdf(std::vector<uint8_t> data, const std::string& name) {
  TCHAR lpTempPathBuffer[MAX_PATH];

  auto ret = GetTempPath(MAX_PATH, lpTempPathBuffer);
  if (ret > MAX_PATH || (ret == 0)) {
    return false;
  }

  auto filename = fromUtf8(toUtf8(lpTempPathBuffer) + "\\" + name);

  auto output_file =
      std::basic_ofstream<uint8_t>{filename, std::ios::out | std::ios::binary};
  output_file.write(data.data(), data.size());
  output_file.close();

  SHELLEXECUTEINFO ShExecInfo;
  ShExecInfo.cbSize = sizeof(SHELLEXECUTEINFO);
  ShExecInfo.fMask = 0;
  ShExecInfo.hwnd = nullptr;
  ShExecInfo.lpVerb = TEXT("open");
  ShExecInfo.lpFile = filename.c_str();
  ShExecInfo.lpParameters = nullptr;
  ShExecInfo.lpDirectory = nullptr;
  ShExecInfo.nShow = SW_SHOWDEFAULT;
  ShExecInfo.hInstApp = nullptr;

  ret = ShellExecuteEx(&ShExecInfo);

  return ret == TRUE;
}

void PrintJob::pickPrinter(void* result) {}

void PrintJob::rasterPdf(std::vector<uint8_t> data,
                         std::vector<int> pages,
                         double scale) {
  FPDF_LIBRARY_CONFIG config;
  config.version = 2;
  config.m_pUserFontPaths = nullptr;
  config.m_pIsolate = nullptr;
  config.m_v8EmbedderSlot = 0;
  FPDF_InitLibraryWithConfig(&config);

  auto doc = FPDF_LoadMemDocument64(data.data(), data.size(), nullptr);
  if (!doc) {
    FPDF_DestroyLibrary();
    printing->onPageRasterEnd(this, "Cannot raster a malformed PDF file");
    return;
  }

  auto pageCount = FPDF_GetPageCount(doc);

  if (pages.size() == 0) {
    // Use all pages
    pages.resize(pageCount);
    std::iota(std::begin(pages), std::end(pages), 0);
  }

  for (auto n : pages) {
    if (n >= pageCount) {
      continue;
    }

    auto page = FPDF_LoadPage(doc, n);
    if (!page) {
      continue;
    }

    auto width = FPDF_GetPageWidth(page);
    auto height = FPDF_GetPageHeight(page);

    auto bWidth = static_cast<int>(width * scale);
    auto bHeight = static_cast<int>(height * scale);

    auto bitmap = FPDFBitmap_Create(bWidth, bHeight, 1);
    FPDFBitmap_FillRect(bitmap, 0, 0, bWidth, bHeight, 0x00ffffff);

    FPDF_RenderPageBitmap(bitmap, page, 0, 0, bWidth, bHeight, 0,
                          FPDF_ANNOT | FPDF_LCD_TEXT);

    uint8_t* p = static_cast<uint8_t*>(FPDFBitmap_GetBuffer(bitmap));
    auto stride = FPDFBitmap_GetStride(bitmap);
    size_t l = static_cast<size_t>(bHeight * stride);

    // BGRA to RGBA conversion
    for (auto y = 0; y < bHeight; y++) {
      auto offset = y * stride;
      for (auto x = 0; x < bWidth; x++) {
        auto t = p[offset];
        p[offset] = p[offset + 2];
        p[offset + 2] = t;
        offset += 4;
      }
    }

    printing->onPageRasterized(std::vector<uint8_t>{p, p + l}, bWidth, bHeight,
                               this);

    FPDFBitmap_Destroy(bitmap);
    FPDF_ClosePage(page);
  }

  FPDF_CloseDocument(doc);

  FPDF_DestroyLibrary();

  printing->onPageRasterEnd(this, "");
}

std::map<std::string, bool> PrintJob::printingInfo() {
  return std::map<std::string, bool>{
      {"directPrint", true},     {"dynamicLayout", true}, {"canPrint", true},
      {"canListPrinters", true}, {"canShare", true},      {"canRaster", true},
  };
}

}  // namespace nfet

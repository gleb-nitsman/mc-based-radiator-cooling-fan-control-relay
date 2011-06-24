@ECHO OFF
"C:\Program Files\Atmel\AVR Tools\AvrAssembler2\avrasm2.exe" -S "C:\proj_src\cooler3.1\labels.tmp" -fI -W+ie -o "C:\proj_src\cooler3.1\cooler3.hex" -d "C:\proj_src\cooler3.1\cooler3.obj" -e "C:\proj_src\cooler3.1\cooler3.eep" -m "C:\proj_src\cooler3.1\cooler3.map" -l "C:\proj_src\cooler3.1\cooler3.lst" "C:\proj_src\cooler3.1\cooler3.asm"

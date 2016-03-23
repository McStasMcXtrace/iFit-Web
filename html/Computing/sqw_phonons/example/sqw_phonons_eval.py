# Script file for Python/ASE to compute the modes from /home/farhi/dev/iFit/Objects/@iData/../../Data/POSCAR_Al in /tmp/tp95c90d0f_995c_45bc_93e5_f24a386c9c9c
#   ASE: S. R. Bahn and K. W. Jacobsen, Comput. Sci. Eng., Vol. 4, 56-66, 2002
#   <https://wiki.fysik.dtu.dk/ase>. Built by ifit.mccode.org/Models.html sqw_phononsfrom ase.phonons import Phonons
import numpy
import pickle
# restore Phonon model
fid = open('ph.pkl', 'rb')
ph = pickle.load(fid)
fid.close()
# read HKL locations
HKL = numpy.loadtxt('HKL.txt')
# compute the spectrum
omega_kn = 1000 * ph.band_structure(HKL)
# save the result in FREQ
numpy.savetxt('FREQ', omega_kn)
exit()

# python script built by ifit.mccode.org/Models.html sqw_phonons
# on 18-Mar-2016 16:02:48
# E. Farhi, Y. Debab and P. Willendrup, J. Neut. Res., 17 (2013) 5
# S. R. Bahn and K. W. Jacobsen, Comput. Sci. Eng., Vol. 4, 56-66, 2002.
#
# Computes the dynamical matrix and stores an ase.phonon.Phonons object in a pickle ph.pkl
# Launch with: python sqw_phonons_build.py (and wait...)
from ase.calculators.emt import EMT
from ase.phonons import Phonons
import pickle
# Setup crystal and calculator
import ase.io; configuration = "/home/farhi/dev/iFit/Objects/@iData/../../Data/POSCAR_Al"; atoms = ase.io.read(configuration); 
calc  = EMT()
# Phonon calculator
ph = Phonons(atoms, calc, supercell=(3, 3, 3), delta=0.05)
ph.run()
# Read forces and assemble the dynamical matrix
ph.read(acoustic=True)
# save ph
fid = open('/tmp/tp95c90d0f_995c_45bc_93e5_f24a386c9c9c/ph.pkl','wb')
pickle.dump(ph, fid)
fid.close()
